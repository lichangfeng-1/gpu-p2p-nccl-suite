#!/usr/bin/env bash
# 跨发行版运行器 v2（2026-10-02）
#
# v1 = 同目录 run_all.sh，四个问题：写死 docker、写死 Docker Hub 镜像、用了 -it（无 TTY 直接挂）、
#      结论只 echo 到屏幕不落盘。v1 原样保留不动，本文件是替代入口。
# v2 变化：
#   1) 后端三级降级 docker → podman → native，--backend 可强制；降级前在 TTY 下问一句
#      （容器与原生两路的 CUDA/NCCL 版本不同，结果互不可比，不能悄悄换）。
#   2) 开跑前先过 env-check-v1.sh 的**参考环境对齐门禁**：有阻断项默认不跑（--allow-drift 才强行继续），
#      并把整段体检输出 tee 进日志——结果档案自带口径，事后不必猜这组数字出自什么机器。
#   3) 镜像变量 TORCH_IMG 为主、IMAGE 仅作兼容别名（同族脚本 p2p-suite-run v3 的教训：
#      上层入口脚本把 IMAGE 用作"编译镜像覆盖"的公开口子，使用者一设就把 torch 镜像换掉了）。
#      本地已有即用；没有只打 pull 命令卡，真下不下 10 GiB 由 --pull 决定（不静默起大下载）。
#   4) 去掉 -it、套件只读挂载（容器以 root 跑，可写挂载等于让一次体检有能力改宿主脚本）、日志落盘。
#   5) 退出码与同族 p2p-suite-run v3 对齐：
#      0 全连通 / 1 连通性通过但有 STAGE_FAIL 段 / 2 用法或落盘错误 / 3 跳过未跑 /
#      4 无可用后端 / 6 部分连通 / 7 全不可达 / 8 低于下限（含设了阈值却没数据）/ 9 无判读行。
#   6) PARSE_ONLY=1 OUT=<已有日志> 只做解析不碰 GPU/docker——离线单测判读正则用，与 v3 同口子。
#
# 用法：bash run_all-v2.sh [--backend=auto|docker|podman|native] [--pull] [--allow-drift] [--yes]
# 环境变量：TORCH_IMG  IMAGE(别名)  OUT  NCCL_DEBUG  PYBIN  P2P_IMAGE_MIRRORS(默认空)
#           P2P_FLOOR_GBPS  NCCL_FLOOR_GBPS(默认 0＝只报不卡)  PARSE_ONLY
# 阈值不内置机型经验值（不凭记忆造数）：要卡下限就显式给 P2P_FLOOR_GBPS / NCCL_FLOOR_GBPS。
set -u

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND=auto; PULL=0; ALLOW_DRIFT=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --backend=*)   BACKEND="${a#*=}" ;;
    --pull)        PULL=1 ;;
    --allow-drift) ALLOW_DRIFT=1 ;;
    --yes)         ASSUME_YES=1 ;;
    -h|--help)     sed -n '1,28p' "$0"; exit 0 ;;
    *)             echo "未知参数：$a（-h 看用法）"; exit 2 ;;
  esac
done
case "$BACKEND" in auto|docker|podman|native) ;; *) echo "--backend 只接受 auto|docker|podman|native"; exit 2 ;; esac

TORCH_IMG="${TORCH_IMG:-${IMAGE:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}}"
# 镜像引用会被打进"给你复制执行的命令卡"，含 ; 或换行就等于把命令卡变成另一条命令
case "$TORCH_IMG" in
  ""|*[!A-Za-z0-9._:/@+-]*) echo "!! TORCH_IMG 含非法字符（只允许 字母数字 . _ : / @ + -）：$TORCH_IMG"; exit 2 ;;
esac
NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
OUT="${OUT:-$SRC/p2p-suite-$(date +%Y%m%d-%H%M%S).log}"
P2P_FLOOR_GBPS="${P2P_FLOOR_GBPS:-0}"
NCCL_FLOOR_GBPS="${NCCL_FLOOR_GBPS:-0}"
INSIDE="$SRC/run_suite-inside-v1.sh"

have(){ command -v "$1" >/dev/null 2>&1; }
emit(){ printf '%s\n' "$*"; printf '%s\n' "$*" >> "$OUT"; }

# ---------- 判读解析（与同族 p2p-suite-run v3 同一套 awk，改一处要同步另一处） ----------
parse_and_verdict(){
  LINKS=$(grep -a '摘要:' "$OUT" | grep -av '^P2P_' | tail -1)
  VERDICT=$(grep -a '判读:' "$OUT" | grep -av '^P2P_' | head -1)
  # pair 行＝P2P BANDWIDTH 段内、首列形如 0->1 的四列行；busbw＝NCCL 段内首列为尺寸标签的四列行取最大。
  MINBW=$(awk -F'|' '/^===== NCCL BANDWIDTH/{s="nccl"} /^===== P2P BANDWIDTH/{s="p2p"} /^===== MULTI-STREAM/{s="ms"}
    s=="p2p" && NF==4 && $1 ~ /^[ \t]*[0-9]+->[0-9]+[ \t]*$/ {a=$2+0;b=$3+0;m=(a<b?a:b); if(min==""||m<min)min=m}
    END{printf "%s", (min==""?"":sprintf("%.2f",min))}' "$OUT")
  BIDIR=$(awk -F'|' '/^===== P2P BANDWIDTH/{s="p2p"} /^===== MULTI-STREAM/{s="ms"}
    s=="p2p" && NF==4 && $1 ~ /^[ \t]*[0-9]+->[0-9]+[ \t]*$/ {if(min==""||$4+0<min)min=$4+0}
    END{printf "%s", (min==""?"":sprintf("%.2f",min))}' "$OUT")
  BUS=$(awk -F'|' '/^===== NCCL BANDWIDTH/{s="nccl"} /^===== P2P BANDWIDTH/{s="p2p"}
    s=="nccl" && NF==4 && $1 ~ /^[ \t]*[0-9.]+(KiB|MiB|GiB)[ \t]*$/ {if($4+0>m)m=$4+0}
    END{printf "%s", (m==""?"":sprintf("%.2f",m))}' "$OUT")
  emit "P2P_LINKS=${LINKS:-<无>}"
  emit "P2P_VERDICT=${VERDICT:-<无判读行>}"
  emit "P2P_MIN_SINGLE_DIR_GBPS=${MINBW:-NA}  P2P_MIN_BIDIR_GBPS=${BIDIR:-NA}  NCCL_MAX_BUSBW_GBPS=${BUS:-NA}"
  FAIL=0
  if [ -n "$MINBW" ]; then
    awk -v v="$MINBW" -v f="$P2P_FLOOR_GBPS" 'BEGIN{exit !(v+0<f+0)}' && { emit "P2P_FLOOR_FAIL min=$MINBW < floor=$P2P_FLOOR_GBPS"; FAIL=1; }
  elif awk -v f="$P2P_FLOOR_GBPS" 'BEGIN{exit !(f+0>0)}'; then
    emit "P2P_FLOOR_FAIL min=NA 而 floor=$P2P_FLOOR_GBPS（没数据不等于达标）"; FAIL=1
  fi
  if [ -n "$BUS" ]; then
    awk -v v="$BUS" -v f="$NCCL_FLOOR_GBPS" 'BEGIN{exit !(v+0<f+0)}' && { emit "NCCL_FLOOR_FAIL busbw=$BUS < floor=$NCCL_FLOOR_GBPS"; FAIL=1; }
  elif awk -v f="$NCCL_FLOOR_GBPS" 'BEGIN{exit !(f+0>0)}'; then
    emit "NCCL_FLOOR_FAIL busbw=NA 而 floor=$NCCL_FLOOR_GBPS（没数据不等于达标）"; FAIL=1
  fi
  if [ "$FAIL" = 1 ]; then emit "P2P_RESULT=FAIL_FLOOR（低于你设的下限：吞吐不达，别当作通过）"; exit 8; fi
  # 连通性判读过了不等于整轮过了：带宽/NCCL 段 STAGE_FAIL 时结论是残缺的，别报 0
  SF=$(grep -ac '^STAGE_FAIL' "$OUT" 2>/dev/null); SF=${SF:-0}
  case "$VERDICT" in
    *全连通*) if [ "$SF" != 0 ]; then
        emit "P2P_RESULT=PASS_WITH_STAGE_FAILS（连通性通过，但有 $SF 段失败：带宽/NCCL 结论不完整）"; exit 1
      fi
      emit "P2P_RESULT=PASS"; exit 0 ;;
    *部分连通*) emit "P2P_RESULT=WARN_PARTIAL（不可达的 GPU 对会回退 CPU 中转，BIOS 关 ACS 后重测）"; exit 6 ;;
    *全不可达*) emit "P2P_RESULT=FAIL_NOP2P（必须 BIOS 关 ACS/IOMMU，否则 P2P 全走 CPU）"; exit 7 ;;
    *) emit "P2P_RESULT=UNKNOWN（日志里没有判读行，多半是某段 STAGE_FAIL，看 $OUT）"; exit 9 ;;
  esac
}

# ---------- 离线单测路径：只读已有日志做解析，绝不截断它 ----------
if [ "${PARSE_ONLY:-0}" = "1" ]; then
  [ -f "$OUT" ] || { echo "PARSE_ONLY 需要已存在的日志文件: $OUT"; exit 2; }
  parse_and_verdict
fi

# 防"把使用者既有文件当日志截掉"：已存在且非空时只允许覆盖 *.log
if [ -s "$OUT" ]; then
  case "$OUT" in *.log) : ;; *) echo "!! OUT 指向已存在的非空文件且不是 .log，拒绝覆盖：$OUT"; exit 2 ;; esac
fi
mkdir -p "$(dirname "$OUT")" 2>/dev/null || { echo "!! 建不了日志目录 $(dirname "$OUT")"; exit 2; }
: > "$OUT" || { echo "!! 写不了日志 $OUT"; exit 2; }
[ -f "$SRC/p2p_check.py" ] || { emit "P2P_SKIP 套件目录缺 p2p_check.py: $SRC"; exit 3; }
[ -f "$INSIDE" ] || { emit "P2P_SKIP 缺执行体 $INSIDE（v2 靠它统一容器与原生两条路）"; exit 3; }

emit "P2P_LOG=$OUT"
emit "P2P_SUITE_DIR=$SRC"
emit "P2P_HOST=$(uname -n)  date=$(date '+%F %T')  arch=$(uname -m)"

# ---------- 对齐门禁 ----------
if [ -f "$SRC/env-check-v1.sh" ]; then
  emit "P2P_GATE=env-check-v1.sh 输出如下（参考环境对齐体检，只读）"
  bash "$SRC/env-check-v1.sh" 2>&1 | tee -a "$OUT"
  GRC=${PIPESTATUS[0]}
else
  emit "P2P_GATE=缺 env-check-v1.sh，跳过对齐门禁（结论无口径标注，别和参考混档）"
  GRC=0
fi
case "$GRC" in
  0) ;;
  4) emit "P2P_RESULT=SKIP_NO_BACKEND（没有任何可用后端；按上面 1Panel 与 toolkit 命令卡对齐后重跑）"; exit 4 ;;
  5) if [ "$ALLOW_DRIFT" = 1 ]; then
       emit "P2P_GATE=BLOCK 已被 --allow-drift 放行：结论与参考环境不可比，存档时务必标注"
     else
       emit "P2P_RESULT=SKIP_BLOCKED（有阻断项未跑；按上面命令卡对齐，确认要强行跑加 --allow-drift）"; exit 3
     fi ;;
  *) emit "P2P_RESULT=UNKNOWN_GATE（env-check 返回 rc=$GRC，先手工跑一遍看输出）"; exit 3 ;;
esac

# ---------- 后端判定 ----------
# 部分最小系统没有 coreutils timeout；缺了就直接跑，别把"没 timeout"报成"连不上守护进程"
tmo(){ if have timeout; then timeout "$@"; else shift; "$@"; fi; }
# nvidia-ctk 默认生成的是 nvidia.yaml，只 glob *.json 会让 podman 后端永远认不出来
cdi_present(){ ls /etc/cdi/*.json /etc/cdi/*.yaml /etc/cdi/*.yml \
                /run/cdi/*.json /run/cdi/*.yaml /var/run/cdi/*.json /var/run/cdi/*.yaml 2>/dev/null | head -1 | grep -q .; }
# docker 的 --gpus all 走的是 daemon 里注册的 nvidia runtime，不读 CDI：
# 用 nvidia-ctk+CDI 兜底会把"干净的 exit 4"变成"容器起不来 rc=9"，所以判据不收它。
# podman 才走 CDI（cdi_present），两条路各用各的判据，不共用。
ok_docker(){ have docker && tmo 10 docker info >/dev/null 2>&1 \
  && tmo 10 docker info -f '{{json .Runtimes}}' 2>/dev/null | grep -aq nvidia; }
ok_podman(){ have podman && tmo 15 podman info >/dev/null 2>&1 && cdi_present; }
NATIVE_PY=""
ok_native(){
  local c
  for c in "${PYBIN:-}" python3 python; do
    [ -n "$c" ] && have "$c" || continue
    "$c" -c 'import torch; assert torch.cuda.is_available() and torch.cuda.device_count()>=1' >/dev/null 2>&1 \
      && { NATIVE_PY="$c"; return 0; }
  done
  return 1
}
choose(){
  case "$1" in
    docker) ok_docker && { ENGINE=docker; RUN_MODE=container; return 0; } ;;
    podman) ok_podman  && { ENGINE=podman; RUN_MODE=container; return 0; } ;;
    native) ok_native  && { ENGINE=""; RUN_MODE=native; return 0; } ;;
  esac
  return 1
}
confirm_degrade(){ # $1=缺的，$2=改用的
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ ! -t 0 ]; then emit "P2P_DEGRADE=$1 不可用 → 自动改用 $2（非交互，未询问）"; return 0; fi
  printf '%s 不可用，改用 %s 继续（两路的 CUDA/NCCL 版本不同，结果不可互比）。继续？[y/N] ' "$1" "$2"
  local ans; read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) emit "P2P_RESULT=SKIP_USER_ABORT（选择停在 $1 缺失处）"; exit 3 ;; esac
}

ENGINE=""; RUN_MODE=""
if [ "$BACKEND" != auto ]; then
  choose "$BACKEND" || { emit "P2P_RESULT=SKIP_BACKEND（你指定了 --backend=$BACKEND，但本机不满足条件）"; exit 3; }
else
  if choose docker; then :
  elif choose podman; then confirm_degrade docker podman
  elif choose native; then confirm_degrade "docker/podman" native
  else emit "P2P_RESULT=SKIP_NO_BACKEND（docker/podman/native 三条路都不通）"; exit 4
  fi
fi
emit "P2P_BACKEND=${ENGINE:-none}  P2P_RUN_MODE=$RUN_MODE"
# 降级别只是"换了个后端"，要把缺的那一步说清楚
if have docker && ! ok_docker && have nvidia-ctk; then
  emit "P2P_HINT=docker 在但没注册 nvidia runtime（--gpus all 会失败）：sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
fi

# ---------- GPU 避让（不抢在役引擎的卡） ----------
if have nvidia-smi && [ -n "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | head -1)" ]; then
  emit "P2P_RESULT=SKIP_GPU_BUSY（GPU 上有其它计算进程，体检不抢卡）"; exit 3
fi

# ---------- 镜像解析（仅容器路径） ----------
# 默认只认基线 TORCH_IMG 本身；P2P_IMAGE_MIRRORS 由使用者自己填（本脚本不内置第三方加速站）。
# 只换 registry 前缀、不换 tag，避免拉回来一个版本不同的镜像还以为同源。
img_candidates(){
  printf '%s\n' "$TORCH_IMG"
  # 首段含 . 或 :（或 localhost）才算绝对地址；基线 pytorch/pytorch:tag 的首段是组织名，
  # 早先按"有没有斜杠"判会让 mirror 前缀对默认镜像整体失效——而它正是打印给使用者的那条补救命令
  first="${TORCH_IMG%%/*}"; [ "$first" = "$TORCH_IMG" ] && return 0
  case "$first" in localhost|*.*|*:*) return 0 ;; esac
  [ -n "${P2P_IMAGE_MIRRORS:-}" ] || return 0
  local m
  # 同样走 while read：for $(...) 会让域名里的 * 被当前目录文件名展开
  while IFS= read -r m; do
    m="${m%/}"; [ -n "$m" ] && printf '%s/%s\n' "$m" "$TORCH_IMG"
  done < <(printf '%s\n' "$P2P_IMAGE_MIRRORS" | tr ',' '\n')
  return 0
}
REF=""
if [ "$RUN_MODE" = container ]; then
  # while read 而不是 for $(...)：引用里出现空格或 * 时，词分割与路径展开会造出凭空的候选
  while IFS= read -r c; do
    # </dev/null：docker/podman 的 inspect 会读 stdin，不掐掉会吃掉循环要读的下一行
    "$ENGINE" image inspect "$c" >/dev/null 2>&1 </dev/null && { REF="$c"; break; }
  done < <(img_candidates)
  if [ -z "$REF" ] && [ "$PULL" = 1 ]; then
    while IFS= read -r c; do
      emit "P2P_PULL_BEGIN $c"
      "$ENGINE" pull "$c" </dev/null 2>&1 | tee -a "$OUT"
      # 管道后 $? 是 tee 的状态；不取 PIPESTATUS 就会把失败的拉取记成 P2P_PULL_OK
      if [ "${PIPESTATUS[0]}" = 0 ]; then REF="$c"; emit "P2P_PULL_OK $c"; break
      else emit "P2P_PULL_FAIL $c"; fi
    done < <(img_candidates)
  fi
  if [ -z "$REF" ]; then
    emit "P2P_RESULT=SKIP_NO_IMAGE（本地没有 torch 镜像，且未开 --pull）"
    emit "对齐动作（约 10 GiB，建议自己后台跑，别在前台等）："
    emit "  nohup $ENGINE pull $TORCH_IMG > $SRC/pull.log 2>&1 &   然后 tail -f $SRC/pull.log"
    emit "国内要换加速入口时，域名交给你自己选定的那个（本脚本不内置第三方加速站）："
    emit "  P2P_IMAGE_MIRRORS=<你的域名> TORCH_IMG=$TORCH_IMG bash run_all-v2.sh --pull"
    emit "或直接用本机已有的 torch 镜像： TORCH_IMG=<你的镜像:tag> bash run_all-v2.sh"
    exit 3
  fi
  emit "P2P_IMAGE_REF=$REF"
  [ "$REF" = "$TORCH_IMG" ] || emit "P2P_IMAGE_DRIFT=实际用的是 $REF（registry 前缀与基线不同：tag 一致才可比）"
fi

# ---------- 执行 ----------
RC=0
if [ "$RUN_MODE" = native ]; then
  emit "P2P_PYBIN=$NATIVE_PY"
  RUN_MODE=native PYBIN="$NATIVE_PY" NCCL_DEBUG="$NCCL_DEBUG" bash "$INSIDE" 2>&1 | tee -a "$OUT"
  RC=${PIPESTATUS[0]}
# 代价（与在役那条线口径一致，保留但写清楚）：--ipc=host 让容器看得见宿主 SysV 共享内存段，
# 且容器以 root 跑第三方镜像；只读挂载与"有计算进程就避让"是缓解，不是隔离。
elif [ "$ENGINE" = docker ]; then
  docker run --rm --gpus all --ipc=host \
    --ulimit memlock=-1 --ulimit stack=67108864 \
    -e NCCL_DEBUG="$NCCL_DEBUG" -e RUN_MODE=container \
    -v "$SRC:/tests:ro" -w /tests \
    "$REF" bash /tests/run_suite-inside-v1.sh 2>&1 | tee -a "$OUT"
  RC=${PIPESTATUS[0]}
else
  # podman 不支持 --gpus，走 CDI；label=disable 防 SELinux 挡住只读挂载的读取
  podman run --rm --device nvidia.com/gpu=all --security-opt label=disable --ipc=host \
    --ulimit memlock=-1 --ulimit stack=67108864 \
    -e NCCL_DEBUG="$NCCL_DEBUG" -e RUN_MODE=container \
    -v "$SRC:/tests:ro" -w /tests \
    "$REF" bash /tests/run_suite-inside-v1.sh 2>&1 | tee -a "$OUT"
  RC=${PIPESTATUS[0]}
fi

STAGEFAILS=$(grep -ac '^STAGE_FAIL' "$OUT" 2>/dev/null); STAGEFAILS=${STAGEFAILS:-0}
emit "P2P_STAGE_FAILS=$STAGEFAILS"
[ "$RC" = 0 ] || emit "P2P_RUN_FAILED rc=$RC（看 $OUT 尾部；判读行若已产出仍照常解析）"

parse_and_verdict

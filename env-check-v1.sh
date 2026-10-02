#!/usr/bin/env bash
# 参考环境对齐体检 v1（2026-10-02）—— 只读：不装包、不改系统源、不写 daemon.json。
#
# 口径来源：本人 8×T10 服务器（机型 G292-Z20）2026-10-01 实测；与 vllm-sm75 部署包的同名体检同源，不另造数字。
# 设计立场：目标是让使用者**对齐参考环境**，不是适配任意环境。所以三档判定：
#   ALIGNED = 与参考一致，数据可直接与参考比对
#   DRIFT   = 能跑，但与参考不同 → 产出的带宽/延迟数字不可与参考互比（必须落档标注）
#   BLOCK   = 跑不起来，给对齐动作
# 与分享包 v4 的差别只在语义映射：v4 里 gpu_count!=8 是 INCOMPAT（因为 TP8 模板），
# 本套件是点对点带宽测试，2~8 卡都能跑，所以降为 DRIFT。
#
# 用法：bash env-check-v1.sh          体检 + 缺失项命令卡
#       bash env-check-v1.sh --net    额外端点探活（每个最多 6s，需 curl）
# 单元测注入：OSREL=<假 os-release>  SKIP_NET=1  ASSUME_YES=1
# 退出码（与分享包 v4 同义，run_all-v2.sh 按此门禁）：
#   0=OK 或 DRIFT（可继续）  4=硬缺（没有任何可用后端）  5=BLOCK（差异过大，需 --allow-drift 才继续）
set -u

NET=0; [ "${1:-}" = "--net" ] && NET=1
[ $# -gt 1 ] && { echo "用法: bash env-check-v1.sh [--net]"; exit 2; }
say(){ printf '%s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
# "真能跑才认"：命令存在不等于能用（坏软链、半截 venv、Windows 商店别名都会存在但 rc≠0）
run_ok(){ "$@" >/dev/null 2>&1; }
tmo(){ if have timeout; then timeout "$1" "${@:2}" 2>/dev/null; else shift; "$@" 2>/dev/null; fi; }
osrel_get(){ grep -m1 "^$1=" "${OSREL:-/etc/os-release}" 2>/dev/null | cut -d= -f2- | tr -d '"'; }

D_N=0; B_N=0; D_LIST=""; B_LIST=""
aligned(){ say "ALIGNED $1 = $2"; }
drift(){ say "DRIFT   $1 = $2"; D_N=$((D_N+1)); D_LIST="$D_LIST $1"; }
block(){ say "BLOCK   $1 = $2"; B_N=$((B_N+1)); B_LIST="$B_LIST $1"; }
note(){ say "note    $1"; }

say "===== 参考环境（对齐目标；实测 2026-10-01 @ G292-Z20） ====="
say "ref_os=Ubuntu 24.04.x LTS | ref_kernel=6.8.x | ref_docker=29.8.0 | ref_driver=580.173.02"
say "ref_gpu=Tesla T10 16384MiB x8 | ref_sm=7.5 | ref_cuda_rt=12.9.1 | ref_glibc=2.39 | ref_python=3.12"
say "ref_torch_img=pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime"
say "（DRIFT 不等于失败：结论仍会产出，但这台机器的数字不能和参考直接比）"
say ""

say "===== 1. 系统与架构 ====="
OS_ID="$(osrel_get ID)"; OS_LIKE="$(osrel_get ID_LIKE)"; OS_CODE="$(osrel_get VERSION_CODENAME)"
OS_PRETTY="$(osrel_get PRETTY_NAME)"
FAMILY=unknown
case " ${OS_ID:-} ${OS_LIKE:-} " in
  *ubuntu*) FAMILY=ubuntu ;;
  *debian*) FAMILY=debian ;;
  *rhel*|*fedora*|*centos*) FAMILY=rhel ;;
esac
if [ -z "$OS_ID" ]; then
  block "os" "读不到 ${OSREL:-/etc/os-release}（非 Linux？），发行版分支命令卡生成不了"
elif [ "$FAMILY" = ubuntu ]; then
  case "$OS_CODE" in
    noble|24.04*) aligned "os" "$OS_PRETTY（与参考同款）" ;;
    jammy|22.04*) drift "os" "$OS_PRETTY（参考 24.04；glibc/默认 python 不同，P2P 结论口径会变）" ;;
    *)            drift "os" "$OS_PRETTY（Ubuntu $OS_CODE，未在参考环境验证）" ;;
  esac
elif [ "$FAMILY" = debian ]; then
  drift "os" "$OS_PRETTY（Debian 系：apt 分支可用，但默认 python 与 glibc 与参考不同，属漂移）"
else
  drift "os" "$OS_PRETTY（id=$OS_ID like=${OS_LIKE:-none}：非 Debian/Ubuntu 家族，本脚本命令卡按 apt 写，不适用）"
fi
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  NARCH=x86_64; MULTIARCH=x86_64-linux-gnu ;;
  aarch64|arm64) NARCH=arm64;  MULTIARCH=aarch64-linux-gnu ;;
  *)             NARCH=unknown; MULTIARCH=unknown ;;
esac
if have dpkg-architecture; then MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "$MULTIARCH"); fi
if [ "$NARCH" = unknown ]; then
  drift "arch" "$ARCH（未映射到 NVIDIA 仓库的 \$(ARCH) 取值，命令卡里的包路径需自查）"
else
  aligned "arch" "$ARCH → nvidia_arch=$NARCH multiarch=$MULTIARCH"
fi
GLIBC=$( { getconf GNU_LIBC_VERSION 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' || true; } | head -1)
[ -n "$GLIBC" ] || GLIBC=$( { ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true; } | head -1)
say "kernel=$(uname -r)  glibc=${GLIBC:-unknown}（参考 2.39）  locale=${LC_ALL:-${LANG:-未设置}}"
case "$(uname -r)" in 6.8*) aligned kernel 6.8.x ;; *) drift kernel "$(uname -r)（参考 6.8.x）" ;; esac
[ -n "$GLIBC" ] && { [ "$GLIBC" = 2.39 ] && aligned glibc 2.39 || drift glibc "$GLIBC（参考 2.39：影响 vllm/torch wheel 兼容）"; }
case "${LC_ALL:-${LANG:-}}" in *UTF-8*|*utf8*) ;; *) drift locale "未设 UTF-8（中文输出会变问号，判读行仍可用）" ;; esac

say ""
say "===== 2. 容器运行时（缺了走 1Panel，见本节末命令卡） ====="
B_DOCKER=no; B_PODMAN=no; B_NATIVE=no; DOCKER_ABSENT=no; NEED_CTK=no
if have docker; then
  if tmo 10 docker info; then
    DV=$(tmo 10 docker version --format '{{.Server.Version}}')
    if [ -z "$DV" ]; then
      block "docker" "命令在但读不到 Server.Version（守护进程未启动 / 当前用户不在 docker 组）"
      DOCKER_ABSENT=yes
    else
      B_DOCKER=yes
      DMAJ=${DV%%.*}
      if [ "${DMAJ:-0}" -ge 29 ] 2>/dev/null; then aligned docker "server=$DV（参考 29.8.0）"
      elif [ "${DMAJ:-0}" -ge 24 ] 2>/dev/null; then drift docker "server=$DV（参考 29.8.0，本套件未在 24~28 上验证）"
      else drift docker "server=$DV（<24，分享包与参考环境都未验证过，建议对齐 29.8.0）"; fi
      RTS=$(docker info -f '{{json .Runtimes}}' 2>/dev/null); [ -n "$RTS" ] || RTS=$(docker info 2>/dev/null | sed -n '/Runtimes:/,$p')
      if printf '%s' "$RTS" | grep -aq nvidia; then
        aligned gpu_runtime "docker runtimes 含 nvidia"
      elif have nvidia-ctk || have nvidia-container-runtime; then
        note "docker runtimes 未列 nvidia，但 nvidia-ctk/nvidia-container-runtime 在 PATH（CDI 或旧配置形态，起容器时自验）"
      else
        block gpu_runtime "docker 在但缺 nvidia-container-toolkit（--gpus all 必失败）→ 见第 5 节命令卡"
        NEED_CTK=yes
        B_DOCKER=no
      fi
    fi
  else
    block docker "已安装但守护进程连不上：sudo systemctl status docker；当前用户需在 docker 组（newgrp docker 后立即生效）"
    DOCKER_ABSENT=yes
  fi
else
  block docker "未安装 → 建议用 1Panel 一键装并管理（见下方命令卡）"
  DOCKER_ABSENT=yes
fi

if have podman; then
  if tmo 15 podman info; then
    if ls /etc/cdi/*.json /etc/cdi/*.yaml /etc/cdi/*.yml /var/run/cdi/*.json /var/run/cdi/*.yaml /run/cdi/*.json /run/cdi/*.yaml 2>/dev/null | head -1 | grep -q .; then
      B_PODMAN=yes; aligned podman "可用且已有 CDI 规格（--device nvidia.com/gpu=all 的前提）"
    else
      note "podman 可用但无 CDI 规格 → 需 sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 才能在容器内看到 GPU"
    fi
  else
    note "podman 命令在但 podman info 失败（不作为后端）"
  fi
fi

say ""
if [ "$DOCKER_ABSENT" = yes ] && [ "$B_PODMAN" = no ]; then
  say "--- docker 不可用（未安装或守护进程连不上）→ 1Panel 安装卡 ---"
  say "单向推荐：本脚本不代跑、不接管、装完也不校验 1Panel 自身状态。"
  say "适用：CentOS / Ubuntu / Debian 等主流发行版，及麒麟、统信等国产系统；"
  say "      架构 x86_64 / aarch64 / armv7l / ppc64le / s390x / riscv64。需 root。"
  say "  bash -c \"\$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)\""
  say "官网（安装链接失效时以官网为准）：https://1panel.cn/"
  say "内网离线安装：见官网《1Panel 离线安装指南》。"
  say "代价（先看清楚再装）：1Panel 会装并接管自己的 docker，并开放一个 Web 管理面板端口；"
  say "      在役生产机（已有容器在跑）装它属于额外攻击面与运行时变更，建议只用于新机或测试机。"
  say "装完后重跑本脚本确认 docker 与 nvidia-container-toolkit 两项，再跑 run_all-v2.sh。"
  say "---------------------------------------------------------------------------"
fi

say "===== 3. 驱动与 GPU（只报要求，不给安装命令） ====="
NGPU=""
if have nvidia-smi; then
  # 计数走 query 接口；-L 的前缀格式一变，grep 会恒 0 → 假 BLOCK
  NGPU=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | grep -c .)
  [ "${NGPU:-0}" != 0 ] || NGPU=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ')
  DRV=$(tmo 10 nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ')
  GN=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  GM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)
  say "driver=${DRV:-?}  gpus=${NGPU:-0}  name=${GN:-?}  mem=${GM:-?}MiB  sm=${SM:-?}"
  say "要求：宿主驱动 ≥570（CUDA 12.9 下限），参考 580.173.02；驱动与 libnvidia-api 配套，换驱动需重新核对。"
  say "      驱动/CUDA 的安装与排错请使用者按自己机型自行处理，本脚本刻意不给命令（装错驱动会打挂在役机器）。"
  DM=${DRV%%.*}
  case "$DM" in ''|*[!0-9]*) DM=unknown ;; esac
  if [ -z "$NGPU" ] || [ "$NGPU" = 0 ]; then
    block nvidia_smi "nvidia-smi 在但读不到 GPU（驱动未加载 / 设备节点缺失）→ 先跑 sudo nvidia-smi 自查"
  else
    if [ "$DM" = unknown ]; then drift driver "版本读不出（${DRV:-空}）：无法与参考比对，请手工核对 nvidia-smi"
    elif [ "$DM" -ge 570 ] 2>/dev/null; then
      [ "$DRV" = 580.173.02 ] && aligned driver "$DRV（与参考逐字一致）" || drift driver "$DRV（≥570 可跑，参考 580.173.02）"
    else
      block driver "$DRV（<570，低于 CUDA 12.9 下限）"
    fi
    if [ "$NGPU" -ge 2 ] 2>/dev/null; then
      [ "$NGPU" = 8 ] && aligned gpu_count 8 || drift gpu_count "$NGPU（参考 8：链路数与并发段结论与 8 卡不可比）"
    else
      block gpu_count "$NGPU（P2P/NCCL 带宽测试至少需 2 卡）"
    fi
    case "$GN" in *T10*) aligned gpu_model "$GN" ;; *) drift gpu_model "${GN:-未知}（参考 Tesla T10：PCIe 代际与链路宽度不同，带宽上限不同）" ;; esac
  NUNAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | grep -c .)
  [ "${NUNAME:-1}" = 1 ] || drift gpu_mix "机型不统一（$NUNAME 种）：上面取的是第一张卡，不代表全部"
    [ "$SM" = 7.5 ] || drift compute_cap "${SM:-未知}（参考 7.5）"
  fi
  BUSY=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -c .)
  [ "$BUSY" = 0 ] || note "GPU 上有 $BUSY 个计算进程在跑：run_all-v2.sh 会避让（不抢卡）"
else
  block nvidia_smi "宿主机没有 nvidia-smi：容器内也拿不到 GPU（nvidia-container-toolkit 依赖宿主驱动）"
fi

say ""
say "===== 4. 解释器与库路径（py 版本强制对齐的判据） ====="
PY=""
if [ -n "${PYBIN:-}" ] && run_ok "$PYBIN" -c 'import sys'; then PY="$PYBIN";
else for c in python3 python; do have "$c" && run_ok "$c" -c 'import sys' && { PY="$c"; break; }; done; fi
if [ -z "$PY" ]; then
  block python "没有能真跑起来的 python3（原生模式不可用；容器模式仍可用镜像内的 python）"
else
  PV=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)
  SP=$("$PY" -c 'import sysconfig;print(sysconfig.get_paths()["purelib"])' 2>/dev/null)
  say "python=$PY 版本=${PV:-?} purelib=${SP:-?} prefix=$("$PY" -c 'import sys;print(sys.prefix)' 2>/dev/null)"
  if [ "$PV" = 3.12 ]; then aligned python "3.12（与参考一致；补丁层按 3.12 + dist-packages 验证）"
  else drift python "$PV（参考 3.12：写死 python3.12 路径的补丁层会 FileNotFoundError，需按 purelib 解析）"; fi
  case "$SP" in
    *dist-packages) aligned py_layout dist-packages ;;
    *site-packages) drift py_layout "site-packages（参考是 dist-packages：Debian/Ubuntu 系统 pip 与 venv/conda 的落点不同）" ;;
    *) [ -n "$SP" ] && drift py_layout "$SP" ;;
  esac
  if run_ok "$PY" -c 'import torch'; then
    TV=$("$PY" -c 'import torch;print(torch.__version__)' 2>/dev/null)
    if [ "$("$PY" -c 'import torch;print(int(torch.cuda.is_available()))' 2>/dev/null || echo 0)" = 1 ]; then
      B_NATIVE=yes
      aligned native_torch "torch=$TV CUDA 可用 卡数=$("$PY" -c 'import torch;print(torch.cuda.device_count())' 2>/dev/null)"
      [ "$TV" = 2.4.1 ] || drift native_torch_ver "$TV（参考镜像内是 2.4.1+cu124：跨版本带宽结论口径不同）"
    else
      note "本机 torch=$TV 导入正常但 cuda.is_available()=False → 原生模式不作为后端（驱动/torch CUDA 版本不匹配）"
    fi
  else
    note "本机无 torch → 原生模式不可用，需要它时自行 pip 安装（国内请先 export PIP_INDEX_URL=<你自己选定的镜像>）"
  fi
  # vllm 落点：层 3 补丁的 FileNotFoundError 就靠这两行一次定位
  if run_ok "$PY" -c 'import vllm'; then
    note "vllm.__file__=$("$PY" -c 'import vllm,os;print(vllm.__file__)' 2>/dev/null)（本机装了 vllm 时才打，供同机部署脚本定位包路径）"
  fi
fi
for p in "/usr/lib/${MULTIARCH}" /usr/local/cuda/lib64 /usr/local/cuda-12/lib64; do
  [ -d "$p" ] || continue
  F=$(ls "$p" 2>/dev/null | grep -m1 '^libcudart\.so' || true)
  [ -n "$F" ] && note "libcudart 候选：$p/$F"
done
have ldconfig && note "ldconfig: $(ldconfig -p 2>/dev/null | grep -m1 libcudart || echo 未登记（容器内由 torch 自带 lib 兜住）)"

say ""
say "===== 5. nvidia-container-toolkit 命令卡（这一层给命令，因为它不改驱动且可回退） ====="
if [ "$NEED_CTK" = yes ]; then
say "本脚本没有执行下面任何一条，请自行确认后运行（Debian/Ubuntu 同一条即可）："
say "  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
say "  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \\"
say "    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \\"
say "    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
say "  sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
say "  sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
say "  # podman 用户补 CDI： sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
say "验收：docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L  应列出全部卡"
else
  say "跳过（体检没发现缺 GPU 运行时；需要时装 nvidia-container-toolkit，命令见 参考环境对齐清单-v1.md 第 4 节）"
fi

say ""
say "===== 6. 网络端点探活 ====="
if [ "$NET" != 1 ]; then
  say "跳过（加 --net 才实测；默认值一律保持上游基线，本脚本不内置第三方加速域名）"
elif ! have curl; then
  drift curl "没装 curl，无法探活"
else
  for U in https://registry-1.docker.io/v2/ "https://nvidia.github.io/libnvidia-container/stable/deb/${NARCH}/" https://pypi.org/simple/; do
    CODE=$(tmo 6 curl -sS -o /dev/null -w '%{http_code}' "$U" | head -1)
    if [ -n "$CODE" ] && [ "$CODE" != 000 ]; then say "reach $CODE  $U"; else say "reach 无响应  $U"; fi
  done
  note "以上为本机当次实测，不代表普遍可用；镜像加速域名请自己选定后用 TORCH_IMG / P2P_IMAGE_MIRRORS / PIP_INDEX_URL 传入"
fi

say ""
say "===== 结论 ====="
say "BACKEND_DOCKER=$B_DOCKER  BACKEND_PODMAN=$B_PODMAN  BACKEND_NATIVE=$B_NATIVE"
SUG=none
[ "$B_DOCKER" = yes ] && SUG=docker
[ "$SUG" = none ] && [ "$B_PODMAN" = yes ] && SUG=podman
[ "$SUG" = none ] && [ "$B_NATIVE" = yes ] && SUG=native
say "SUGGESTED_BACKEND=$SUG"
say "DRIFT_N=$D_N${D_LIST:+  漂移项:$D_LIST}"
say "BLOCK_N=$B_N${B_LIST:+  阻断项:$B_LIST}"
if [ "$B_N" = 0 ] && [ "$D_N" = 0 ]; then say "ENV_VERDICT=OK（与参考环境逐项一致）"; exit 0; fi
if [ "$B_N" = 0 ]; then say "ENV_VERDICT=WARN（可跑，但有漂移项：结论请与参考分开存档）"; exit 0; fi
if [ "$SUG" = none ]; then say "ENV_VERDICT=INCOMPAT 且无任何后端可跑"; exit 4; fi
say "ENV_VERDICT=INCOMPAT（有阻断项；run_all-v2.sh 需 --allow-drift 才继续，风险自负）"
exit 5

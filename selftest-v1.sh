#!/usr/bin/env bash
# 离线自测 v1（2026-10-02）—— 不碰 GPU、不碰真 docker、不联网，全部用桩。
# 覆盖：假 os-release 的发行版分支 / ALIGNED-DRIFT-BLOCK 三档 / 后端可用性判定 /
#       判读解析（全连通·部分·全不可达·无判读·低于下限）/ 参数与早退路径。
# 用法：bash selftest-v1.sh     全过打印 SELFTEST_DONE rc=0
# 已知覆盖缺口：docker "命令根本不存在" 这一支用桩造不出来（command -v 一定会找到桩），
#              它只有一行 if，靠静态阅读保证；桩测的是"装了但守护进程连不上"。
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/p2p-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1 rc=$3"; PASS=$((PASS+1)); else echo "FAIL $1 期望 rc=$2 实得 rc=$3"; FAIL=$((FAIL+1)); fi; }
has(){ if grep -aq "$3" "$2"; then echo "PASS 输出含 $1"; PASS=$((PASS+1)); else echo "FAIL 输出缺: $1（在 $(basename "$2")）"; FAIL=$((FAIL+1)); fi; }

# ---------- 桩 ----------
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  info)    [ "${STUB_DOCKER:-ok}" = no_daemon ] && exit 1
           if [ "${2:-}" = "-f" ]; then
             [ "${STUB_DOCKER:-ok}" = no_runtime ] && printf '%s\n' '{"runc":{"path":"runc"}}' || printf '%s\n' '{"nvidia":{"path":"nvidia-container-runtime"},"runc":{}}'
             exit 0
           fi
           exit 0 ;;
  version) echo "${STUB_DOCKER_VER:-29.8.0}" ;;
  image)   [ "${STUB_IMAGE:-present}" = present ] ;;
  pull)    if [ "${STUB_PULL:-ok}" = ok ]; then echo "pull $2"; else echo "stub: pull denied" >&2; exit 1; fi ;;
  *)       exit 0 ;;
esac
EOS
cat > "$T/bin/podman" <<'EOS'
#!/usr/bin/env bash
[ "${STUB_PODMAN:-absent}" = ok ] || exit 127
case "$1" in info) exit 0 ;; esac
EOS
cat > "$T/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
[ "${STUB_NVIDIA:-ok}" = ok ] || exit 1
case "$*" in
  *query-compute-apps*) exit 0 ;;
  *-L*) for i in 0 1 2 3 4 5 6 7; do echo "GPU $i: Tesla T10 (UUID: GPU-stub-$i)"; done ;;
  *driver_version*) echo "${STUB_DRV:-580.173.02}" ;;
  *memory.total*) echo "16384" ;;
  *compute_cap*) echo "7.5" ;;
  *name*) if [ "${STUB_MIX:-0}" = 1 ]; then echo "Tesla T10"; echo "NVIDIA A100"; else echo "Tesla T10"; fi ;;
  *index*) for i in 0 1 2 3 4 5 6 7; do echo "$i"; done ;;
  *topo*) echo "GPU0 stub topo" ;;
  *) exit 0 ;;
esac
EOS
cat > "$T/bin/python3" <<'EOS'
#!/usr/bin/env bash
[ "${STUB_PY:-ok312}" != none ] || exit 1
code="${2:-}"
case "$code" in
  *vllm*) exit 1 ;;
  *%d.%d*) echo "${STUB_PYVER:-3.12}"; exit 0 ;;
  *purelib*) echo "${STUB_PURELIB:-/usr/local/lib/python3.12/dist-packages}"; exit 0 ;;
  *sys.prefix*) echo /usr/local; exit 0 ;;
  *torch.__version__*) [ "${STUB_PY:-ok312}" = notorch ] && exit 1; echo 2.4.1; exit 0 ;;
  *cuda.is_available*) [ "${STUB_PY:-ok312}" = notorch ] && exit 1; echo "${STUB_CUDA:-1}"; exit 0 ;;
  *device_count*) [ "${STUB_PY:-ok312}" = noise ] && echo "UserWarning: stub noise"; echo 8; exit 0 ;;
  *version.split*) echo 3.12.3; exit 0 ;;
  *assert*) [ "${STUB_PY:-ok312}" = notorch ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
EOS
cat > "$T/bin/python" <<'EOS'
#!/usr/bin/env bash
# PATH 已含桩目录，python3 会命中上面那个桩（不是系统 python），所以这里不会自递归
exec python3 "$@"
EOS
cat > "$T/bin/timeout" <<'EOS'
#!/usr/bin/env bash
# 桩版 timeout：丢掉第一个数字参数，直接执行（真 timeout 在部分环境不存在）
shift; exec "$@"
EOS
chmod +x "$T"/bin/* 2>/dev/null
export PATH="$T/bin:$PATH"

# ---------- 假 os-release ----------
mk_osrel(){ printf 'NAME="%s"\nID=%s\nID_LIKE="%s"\nVERSION_CODENAME=%s\nPRETTY_NAME="%s"\n' "$2" "$3" "$4" "$5" "$6" > "$T/osrel.$1"; }
mk_osrel ubuntu2404 Ubuntu ubuntu "" noble "Ubuntu 24.04.3 LTS"
mk_osrel ubuntu2204 Ubuntu ubuntu "" jammy "Ubuntu 22.04.5 LTS"
mk_osrel debian12 Debian debian "" bookworm "Debian GNU/Linux 12 (bookworm)"
mk_osrel centos CentOS rhel fedora "" "CentOS Stream 9"

echo "=== T1 Ubuntu 24.04 + 全对齐 → rc=0 ==="
# 不断言 ENV_VERDICT=OK：桩跑在什么宿主上就会漂什么（kernel/glibc/locale 一定不是 24.04 的值），
# 这里要验的是"对齐项被认出来"＋"无阻断即放行"，不是宿主本身。
L="$T/t1.log"; STUB_DOCKER=ok OSREL="$T/osrel.ubuntu2404" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T1 0 $?
has "os ALIGNED" "$L" "ALIGNED os"; has "docker ALIGNED" "$L" "ALIGNED docker"
has "driver 逐字对齐" "$L" "ALIGNED driver = 580.173.02"; has "BACKEND_DOCKER=yes" "$L" "BACKEND_DOCKER=yes"
has "无阻断项" "$L" "BLOCK_N=0"

echo "=== T2 Debian 12 → DRIFT os，仍可跑 rc=0 ==="
L="$T/t2.log"; STUB_DOCKER=ok OSREL="$T/osrel.debian12" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T2 0 $?
has "os DRIFT" "$L" "DRIFT   os"; has "VERDICT=WARN" "$L" "ENV_VERDICT=WARN"

echo "=== T3 无 nvidia 运行时 → BLOCK gpu_runtime，降级 native 仍可 → rc=5 ==="
L="$T/t3.log"; STUB_DOCKER=no_runtime OSREL="$T/osrel.ubuntu2404" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T3 5 $?
has "BLOCK gpu_runtime" "$L" "BLOCK   gpu_runtime"; has "SUGGESTED=native" "$L" "SUGGESTED_BACKEND=native"
has "toolkit 命令卡" "$L" "nvidia-container-toolkit.list"

echo "=== T4 docker 守护进程挂 + 本机无 torch → 无后端 rc=4 + 1Panel 卡 ==="
L="$T/t4.log"; STUB_DOCKER=no_daemon STUB_PY=notorch OSREL="$T/osrel.ubuntu2404" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T4 4 $?
has "1Panel 安装命令" "$L" "resource.fit2cloud.com/1panel/package/v2/quick_start.sh"
has "1Panel 官网" "$L" "https://1panel.cn/"

echo "=== T5 python 3.11 + site-packages → 两项 DRIFT（py 对齐判据） ==="
L="$T/t5.log"; STUB_PYVER=3.11 STUB_PURELIB=/opt/venv/lib/python3.11/site-packages OSREL="$T/osrel.ubuntu2404" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T5 0 $?
has "python DRIFT" "$L" "DRIFT   python"; has "py_layout DRIFT" "$L" "DRIFT   py_layout"

echo "=== T6 非 apt 家族（CentOS）→ 只报漂移不崩 ==="
L="$T/t6.log"; STUB_DOCKER=ok OSREL="$T/osrel.centos" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T6 0 $?
has "os DRIFT(非家族)" "$L" "非 Debian/Ubuntu 家族"

echo "=== T7 判读解析（PARSE_ONLY 五档） ==="
fix(){ # fix <文件> <判读行> <pair行> <nccl行>
  { echo "===== NCCL BANDWIDTH (all_reduce, all GPUs) ====="
    echo "      size |        bytes |  algbw GB/s |  busbw GB/s"
    echo "$3"
    echo "===== P2P BANDWIDTH (1 GiB, both directions + bidirectional) ====="
    echo "   pair |   1GiB i->j |   1GiB j->i |  bidir GB/s"
    echo "$2"
    echo "===== MULTI-STREAM CONCURRENT P2P ====="
    [ -n "$4" ] && echo "$4"; } > "$1"
}
fix "$T/pass.log" "   0->1 |       13.16 |        6.59 |       13.15" "    32MiB |     33554432 |       12.10 |       11.53" "判读: 全连通 — P2P mesh 完整"
fix "$T/part.log" "   0->1 |       13.16 |        6.59 |       13.15" "    32MiB |     33554432 |       12.10 |       11.53" "判读: 部分连通 — 不可达的 GPU 对会回退 CPU 中转"
fix "$T/no.log"   "   0->1 |       13.16 |        6.59 |       13.15" "    32MiB |     33554432 |       12.10 |       11.53" "判读: 全不可达 — 必须进 BIOS 关闭 ACS / IOMMU"
printf '===== P2P DIAGNOSTICS =====\nSTAGE_FAIL sanity\n' > "$T/none.log"
for c in pass part no none; do
  OUT="$T/$c.log" PARSE_ONLY=1 bash "$SRC/run_all-v2.sh" > "$T/$c.out" 2>&1; rc=$?
  case $c in pass) want=0;; part) want=6;; no) want=7;; none) want=9;; esac
  chk "T7-$c" "$want" "$rc"
done
has "MIN 解析出 6.59" "$T/pass.log" "P2P_MIN_SINGLE_DIR_GBPS=6.59"
has "BIDIR 解析出 13.15" "$T/pass.log" "P2P_MIN_BIDIR_GBPS=13.15"
has "busbw 解析出 11.53" "$T/pass.log" "NCCL_MAX_BUSBW_GBPS=11.53"
OUT="$T/pass.log" PARSE_ONLY=1 P2P_FLOOR_GBPS=20 bash "$SRC/run_all-v2.sh" > "$T/floor.out" 2>&1; chk "T7-floor" 8 $?
has "floor 判读" "$T/pass.log" "P2P_FLOOR_FAIL"

echo "=== T8 参数与早退 ==="
bash "$SRC/run_all-v2.sh" --nonsense > "$T/a1.out" 2>&1; chk "未知参数" 2 $?
bash "$SRC/run_all-v2.sh" --backend=foo > "$T/a2.out" 2>&1; chk "非法 backend" 2 $?
bash "$SRC/run_all-v2.sh" -h > "$T/a3.out" 2>&1; chk "帮助" 0 $?
PARSE_ONLY=1 OUT="$T/not-exist.log" bash "$SRC/run_all-v2.sh" > "$T/a4.out" 2>&1; chk "PARSE_ONLY 缺日志" 2 $?

echo "=== T9 无门禁脚本 + 三后端全不通 → rc=4（不静默跑空） ==="
mkdir -p "$T/suite" && cp "$SRC"/run_all-v2.sh "$SRC"/run_suite-inside-v1.sh "$SRC"/p2p_check.py "$T/suite/"
STUB_DOCKER=no_daemon STUB_PY=notorch OUT="$T/s9.log" PARSE_ONLY=0 bash "$T/suite/run_all-v2.sh" > "$T/s9.out" 2>&1; chk T9 4 $?
has "缺门禁的标注" "$T/s9.log" "跳过对齐门禁"
has "无后端结论" "$T/s9.log" "SKIP_NO_BACKEND"

echo "=== T10 默认镜像也要能吃 mirror 前缀；pull 失败不得记成 OK（回归） ==="
L="$T/t10.log"
STUB_DOCKER=ok STUB_IMAGE=absent STUB_PULL=fail P2P_IMAGE_MIRRORS=mirror.example \
  OSREL="$T/osrel.ubuntu2404" OUT="$L" bash "$SRC/run_all-v2.sh" --pull --yes > "$T/t10.out" 2>&1
chk T10 3 $?
has "候选含 mirror 前缀" "$L" "P2P_PULL_BEGIN mirror.example/pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime"
has "失败被记成 FAIL" "$L" "P2P_PULL_FAIL mirror.example/pytorch/pytorch"
if grep -aq "P2P_PULL_OK" "$L"; then echo "FAIL 拉取失败却记了 P2P_PULL_OK"; FAIL=$((FAIL+1)); else echo "PASS 无假 P2P_PULL_OK"; PASS=$((PASS+1)); fi

echo "=== T11 TORCH_IMG 含分号/空格 → 拒在门禁之前（命令卡注入面） ==="
rm -f /tmp/p2p-stub-pwned
TORCH_IMG='pytorch/pytorch; touch /tmp/p2p-stub-pwned' bash "$SRC/run_all-v2.sh" > "$T/t11.out" 2>&1; chk T11 2 $?
[ -e /tmp/p2p-stub-pwned ] && { echo "FAIL 非法镜像名里的命令被执行了"; FAIL=$((FAIL+1)); } || { echo "PASS 未被执行"; PASS=$((PASS+1)); }

echo "=== T12 OUT 指向已存在的非空非 .log 文件 → 拒绝覆盖 ==="
printf 'user-data\n' > "$T/precious.txt"
OUT="$T/precious.txt" bash "$SRC/run_all-v2.sh" > "$T/t12.out" 2>&1; chk T12 2 $?
if [ "$(cat "$T/precious.txt")" = "user-data" ]; then echo "PASS 原文件未被截断"; PASS=$((PASS+1)); else echo "FAIL 原文件被日志覆盖"; FAIL=$((FAIL+1)); fi

echo "=== T13 设了 floor 但没解析到数据 → 不达标（没数据不等于通过） ==="
{ echo "===== NCCL BANDWIDTH (all_reduce, all GPUs) ====="
  echo "      size |        bytes |  algbw GB/s |  busbw GB/s"
  echo "===== P2P BANDWIDTH (1 GiB, both directions + bidirectional) ====="
  echo "   pair |   1GiB i->j |   1GiB j->i |  bidir GB/s"
  echo "===== MULTI-STREAM CONCURRENT P2P ====="
  echo "判读: 全连通 — 但带宽段一行都没有"; } > "$T/nodata.log"
OUT="$T/nodata.log" PARSE_ONLY=1 P2P_FLOOR_GBPS=5 bash "$SRC/run_all-v2.sh" > "$T/t13.out" 2>&1; chk T13 8 $?
has "NA 也判不达" "$T/nodata.log" "min=NA"

echo "=== T14 连通性 PASS 但有段失败 → 降为 rc=1，不报全绿 ==="
fix "$T/sf.log" "   0->1 |       13.16 |        6.59 |       13.15" "    32MiB |     33554432 |       12.10 |       11.53" "判读: 全连通 — P2P mesh 完整"
printf 'STAGE_FAIL NCCL BANDWIDTH (all_reduce, all GPUs)\n' >> "$T/sf.log"
OUT="$T/sf.log" PARSE_ONLY=1 bash "$SRC/run_all-v2.sh" > "$T/t14.out" 2>&1; chk T14 1 $?
has "降级结论行" "$T/sf.log" "PASS_WITH_STAGE_FAILS"

echo "=== T15 本地已有镜像：REF 命中（覆盖 while-read 里 break 与赋值不丢） ==="
L="$T/t15.log"
STUB_DOCKER=ok OSREL="$T/osrel.ubuntu2404" OUT="$L" bash "$SRC/run_all-v2.sh" --yes > "$T/t15.out" 2>&1
has "P2P_IMAGE_REF 命中" "$L" "P2P_IMAGE_REF=pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime"

echo "=== T16 合法镜像引用不被白名单误杀（带端口 registry + digest） ==="
L="$T/t16.log"
TORCH_IMG='reg.example:5000/org/img@sha256:aaaa1111' STUB_DOCKER=ok OSREL="$T/osrel.ubuntu2404" OUT="$L" \
  bash "$SRC/run_all-v2.sh" --yes > "$T/t16.out" 2>&1; rc=$?
[ "$rc" = 2 ] && { echo "FAIL T16 合法引用被拒"; FAIL=$((FAIL+1)); } || { echo "PASS T16 未被误拒 rc=$rc"; PASS=$((PASS+1)); }
has "REF 用了指定的 digest 引用" "$L" "P2P_IMAGE_REF=reg.example:5000/org/img@sha256:aaaa1111"

echo "=== T17 驱动版本读不出 → DRIFT 而非 BLOCK ==="
L="$T/t17.log"
STUB_DRV=n/a OSREL="$T/osrel.ubuntu2404" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T17 0 $?
has "driver DRIFT" "$L" "DRIFT   driver"

echo "=== T18 机型不统一 → gpu_mix DRIFT（head -1 代表不了全部） ==="
L="$T/t18.log"
STUB_MIX=1 OSREL="$T/osrel.ubuntu2404" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T18 0 $?
has "gpu_mix DRIFT" "$L" "DRIFT   gpu_mix"

echo "=== T19 执行体：torch 往 stdout 多吐一行也不能误判成无 GPU ==="
L="$T/t19.out"
STUB_PY=noise PYBIN=python3 RUN_MODE=native bash "$SRC/run_suite-inside-v1.sh" > "$L" 2>&1
if grep -aq "no-visible-gpu" "$L"; then echo "FAIL T19 噪声行导致误判"; FAIL=$((FAIL+1)); else echo "PASS T19 未误判"; PASS=$((PASS+1)); fi
has "gpus=8 被正确解析" "$L" "gpus=8"

echo "=== T20 docker 在但 runtime 未注册：门禁记漂移，运行器降级并给补齐命令 ==="
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/nvidia-ctk"; chmod +x "$T/bin/nvidia-ctk"
L="$T/t20.log"
STUB_DOCKER=no_runtime OSREL="$T/osrel.ubuntu2404" bash "$SRC/env-check-v1.sh" > "$L" 2>&1; chk T20a 0 $?
has "gpu_runtime DRIFT" "$L" "DRIFT   gpu_runtime"; has "docker 后端关闭" "$L" "BACKEND_DOCKER=no"
has "建议后端降级" "$L" "SUGGESTED_BACKEND=native"
L2="$T/t20b.log"
STUB_DOCKER=no_runtime OSREL="$T/osrel.ubuntu2404" OUT="$L2" bash "$SRC/run_all-v2.sh" --yes > "$T/t20b.out" 2>&1
has "补齐命令提示" "$L2" "nvidia-ctk runtime configure --runtime=docker"
rm -f "$T/bin/nvidia-ctk"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] && { echo "SELFTEST_DONE"; exit 0; } || { echo "SELFTEST_FAILED"; exit 1; }

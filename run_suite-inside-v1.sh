#!/usr/bin/env bash
# 套件执行体 v1（2026-10-02）—— 只依赖 python+torch，容器内与宿主机原生跑同一份。
# 拆成独立文件的原因：v1 把整段测试塞在 docker run 的单引号里，原生模式没法复用，
# 且三层引号会吃掉 heredoc 的反斜杠（本机踩过的坑）。现在容器只执行 bash /tests/本文件。
# 段落标记必须与同族 p2p-suite-run v3 的 awk 解析保持一致
# （===== NCCL BANDWIDTH / ===== P2P BANDWIDTH / ===== MULTI-STREAM），否则判读行解析不到 → 误报 rc=9。
# 每段失败打 STAGE_FAIL <段> 后继续：体检要的是"哪几段过、哪几段不过"，不是第一个错就停。
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SRC" || exit 2
export PYTHONIOENCODING=utf-8

PY="${PYBIN:-}"
if [ -z "$PY" ]; then
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }
  done
fi
[ -n "$PY" ] || { echo "STAGE_FAIL no-python（本机/本镜像没有能真跑起来的 python3）"; exit 2; }
"$PY" -c 'import torch' >/dev/null 2>&1 || { echo "STAGE_FAIL torch-import（$PY 里没有 torch）"; exit 2; }
NG=$("$PY" -c 'import torch;print(torch.cuda.device_count())' 2>/dev/null || echo 0)
[ "${NG:-0}" -ge 1 ] || { echo "STAGE_FAIL no-visible-gpu（torch.cuda.device_count()=$NG）"; exit 2; }

echo "RUN_MODE=${RUN_MODE:-unknown}  python=$("$PY" -c 'import sys;print(sys.version.split()[0])')  torch=$("$PY" -c 'import torch;print(torch.__version__)')  torch_cuda=$("$PY" -c 'import torch;print(torch.version.cuda or "none")')  gpus=$NG"

stage(){ name="$1"; shift; echo; echo "===== $name ====="; "$@" || echo "STAGE_FAIL $name"; }

echo
echo "===== TORCH / GPU SANITY ====="
"$PY" - <<'PY' || echo "STAGE_FAIL sanity"
import torch
print("torch        ", torch.__version__)
print("cuda available", torch.cuda.is_available())
print("device count  ", torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print(f"  GPU{i}: {p.name}  {p.total_memory/2**30:.1f} GiB")
PY

stage "GPU TOPOLOGY (nvidia-smi topo -m)" nvidia-smi topo -m
stage "P2P ACCESS MATRIX" "$PY" p2p_check.py
stage "NCCL BANDWIDTH (all_reduce, all GPUs)" "$PY" -m torch.distributed.run --standalone --nproc_per_node="$NG" nccl_bandwidth.py
stage "P2P BANDWIDTH (1 GiB, both directions + bidirectional)" "$PY" p2p_bandwidth.py
stage "MULTI-STREAM CONCURRENT P2P" "$PY" multistream_p2p.py
stage "P2P DIAGNOSTICS (link gen/width, staged baseline, concurrent pairs)" "$PY" diag_p2p.py

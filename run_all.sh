#!/usr/bin/env bash
# 在 G292-Z20 宿主机上运行：bash run_all.sh
# 依赖：已安装 nvidia-container-toolkit；镜像 pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime 已拉取。
# 脚本目录会挂载进容器 /tests。
# 可用环境变量覆盖：IMAGE=<镜像>  NCCL_DEBUG=<INFO|WARN|NONE>
set -e
IMAGE="${IMAGE:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}"
NCCL_DEBUG="${NCCL_DEBUG:-INFO}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker run --rm -it --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -e NCCL_DEBUG="$NCCL_DEBUG" \
  -v "${SRC}:/tests" -w /tests \
  "$IMAGE" bash -c '
    set -e
    echo "===== TORCH / GPU SANITY ====="
    python - <<PY
import torch
print("torch        ", torch.__version__)
print("cuda available", torch.cuda.is_available())
print("device count  ", torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print(f"  GPU{i}: {p.name}  {p.total_memory/2**30:.1f} GiB")
PY
    echo
    echo "===== GPU TOPOLOGY (nvidia-smi topo -m) ====="
    nvidia-smi topo -m
    echo
    echo "===== P2P ACCESS MATRIX ====="
    python p2p_check.py
    echo
    echo "===== NCCL BANDWIDTH (all_reduce, all GPUs) ====="
    torchrun --nproc_per_node=$(nvidia-smi -L | wc -l) nccl_bandwidth.py
    echo
    echo "===== P2P BANDWIDTH (1 GiB, both directions + bidirectional) ====="
    python p2p_bandwidth.py
    echo
    echo "===== MULTI-STREAM CONCURRENT P2P ====="
    python multistream_p2p.py
    echo
    echo "===== P2P DIAGNOSTICS (link gen/width, staged baseline, concurrent pairs) ====="
    python diag_p2p.py
  '

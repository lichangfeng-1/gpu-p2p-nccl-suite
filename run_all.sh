#!/usr/bin/env bash
# ！v1 基线，非入口：本文件保留作对照，要跑请用 run_all-v2.sh。
# ！v1 的三个已知问题：写死 docker 与 Docker Hub 镜像；-it 在无 TTY（nohup/CI）下直接挂；
# ！结论只 echo 不落盘。另：下面第 11 行的挂载是可写的，容器以 root 跑，等于允许一次体检改写
# ！本目录脚本、下次被执行——v2 已改 :ro。要沿用 v1 请自行把 -v 加上 :ro。
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

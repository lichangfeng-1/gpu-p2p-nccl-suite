#!/usr/bin/env python3
"""NCCL 带宽测试 (all_reduce, ring)。
由 torchrun 启动，每卡一个进程。报告算法带宽(algbw)与总线带宽(busbw)。
busbw = algbw * 2*(n-1)/n  (ring all_reduce 系数)。
最大尺寸 512 MiB 以避免 8 卡同时 1GiB 时显存吃紧 (T10 16GB)。
注: torch.cuda.Event 无 device 参数; Stream 也统一用 set_device 后的当前设备创建，
    不使用 device= 关键字 (torch 2.4 实测 Event 不接受该参数)。
"""
import os
import torch
import torch.distributed as dist


def main():
    local_rank = int(os.environ.get("LOCAL_RANK", 0))
    world = int(os.environ.get("WORLD_SIZE", 1))
    torch.cuda.set_device(local_rank)
    dist.init_process_group("nccl")
    dev = torch.cuda.current_device()

    if local_rank == 0:
        print(f"world_size={world}  backend=NCCL  device={dev}")
        print(f"{'size':>10} | {'bytes':>12} | {'algbw GB/s':>11} | {'busbw GB/s':>11}")

    sizes = [1 << k for k in range(10, 30)]  # 1 KiB .. 512 MiB
    for s in sizes:
        n = s // 4  # float32 元素数
        t = torch.randn(n, dtype=torch.float32, device=dev)
        for _ in range(5):
            dist.all_reduce(t)
        torch.cuda.synchronize()

        st = torch.cuda.Stream()  # 当前设备 = dev
        s_ev = torch.cuda.Event(enable_timing=True)
        e_ev = torch.cuda.Event(enable_timing=True)
        with torch.cuda.stream(st):
            s_ev.record()
            for _ in range(20):
                dist.all_reduce(t)
            e_ev.record()
        torch.cuda.synchronize()

        sec = s_ev.elapsed_time(e_ev) / 1000.0 / 20.0
        algbw = s / sec / 1e9
        busbw = algbw * (2 * (world - 1) / world)
        if local_rank == 0:
            label = f"{s/1024:.0f}KiB" if s < 1 << 20 else f"{s/2**20:.0f}MiB"
            print(f"{label:>10} | {s:>12} | {algbw:>11.2f} | {busbw:>11.2f}", flush=True)

    dist.destroy_process_group()


if __name__ == "__main__":
    main()

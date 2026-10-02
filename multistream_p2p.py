#!/usr/bin/env python3
"""多流并发 P2P：在选定 GPU 对上用 K 条 CUDA stream 同时搬运，
测量聚合带宽随并发流数的变化。覆盖需求中的"多流并发 P2P"。
注: torch.cuda.Event 无 device 参数; Stream/Event 统一在 set_device 后按当前设备创建。
"""
import torch

from p2putil import enable_p2p


def main():
    ng = torch.cuda.device_count()
    pairs = [(i, j) for i in range(ng) for j in range(ng)
             if i != j and torch.cuda.can_device_access_peer(i, j)]
    if not pairs:
        print("No peer-access pairs available; 无法运行多流并发 P2P。")
        return
    i, j = pairs[0]
    enable_p2p(i, j)
    enable_p2p(j, i)
    print(f"使用 GPU{i} -> GPU{j}")

    TOTAL = 1 << 30  # 1 GiB 总量
    print(f"多流并发 P2P: GPU{i} <-> GPU{j}, 总搬运量 {TOTAL/2**30:.0f} GiB")
    print(f"{'streams':>8} | {'elapsed ms':>11} | {'agg GB/s':>10}")
    for k in [1, 2, 4, 8]:
        chunk = TOTAL // k
        srcs = [torch.randn(chunk // 4, dtype=torch.float32, device=i) for _ in range(k)]
        dsts = [torch.empty(chunk // 4, dtype=torch.float32, device=j) for _ in range(k)]

        torch.cuda.set_device(j)
        streams = [torch.cuda.Stream() for _ in range(k)]
        for s_i in range(k):
            dsts[s_i].copy_(srcs[s_i], non_blocking=True)
        torch.cuda.synchronize()

        s_ev = [torch.cuda.Event(enable_timing=True) for _ in range(k)]
        e_ev = [torch.cuda.Event(enable_timing=True) for _ in range(k)]
        for s_i in range(k):
            with torch.cuda.stream(streams[s_i]):
                s_ev[s_i].record()
                dsts[s_i].copy_(srcs[s_i], non_blocking=True)
                e_ev[s_i].record()
        torch.cuda.synchronize()

        elapsed = max(s_ev[s_i].elapsed_time(e_ev[s_i]) for s_i in range(k)) / 1000.0
        bw = TOTAL / elapsed / 1e9
        print(f"{k:>8} | {elapsed*1000:>11.2f} | {bw:>10.2f}", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""P2P 带宽测试：1 GiB 大文件传输、单双向、以及尺寸扫描。
覆盖需求中的：P2P 速度 / 双向 P2P 速度 / 1GB 大文件速度。
T10 走 PCIe 3.0 x16 (插 Gen4 槽会协商降速), 单链路上限约 15.75 GB/s；实测以本机为准。
注: torch.cuda.Event 无 device 参数; Stream/Event 统一在 set_device 后按当前设备创建。
注: torch.cuda.synchronize() 只同步"当前设备"; 跨设备场景必须逐个 sync, 否则计时被污染。
"""
import torch

from p2putil import enable_all


def fmt(n):
    if n >= 1 << 30:
        return f"{n/2**30:.2f}GiB"
    if n >= 1 << 20:
        return f"{n/2**20:.2f}MiB"
    if n >= 1 << 10:
        return f"{n/2**10:.2f}KiB"
    return f"{n}B"


def measure_copy(src_dev, dst_dev, nbytes, iters=20, warmup=5):
    """单方向 P2P 拷贝带宽 (GB/s)。拷贝跑在 dst_dev 的流上, 同步 dst_dev 即可。"""
    torch.cuda.set_device(src_dev)
    src = torch.randn(nbytes // 4, dtype=torch.float32, device=src_dev)
    torch.cuda.set_device(dst_dev)
    dst = torch.empty(nbytes // 4, dtype=torch.float32, device=dst_dev)
    for _ in range(warmup):
        dst.copy_(src, non_blocking=True)
    torch.cuda.synchronize(dst_dev)

    st = torch.cuda.Stream()
    s_ev = torch.cuda.Event(enable_timing=True)
    e_ev = torch.cuda.Event(enable_timing=True)
    with torch.cuda.stream(st):
        s_ev.record()
        for _ in range(iters):
            dst.copy_(src, non_blocking=True)
        e_ev.record()
    torch.cuda.synchronize(dst_dev)

    sec = s_ev.elapsed_time(e_ev) / 1000.0 / iters
    return nbytes / sec / 1e9


def measure_bidir(i, j, nbytes, iters=20, warmup=5):
    """双向并发 P2P 拷贝聚合带宽 (GB/s)，总搬运量 = 2*nbytes。
    关键: 两个设备都要同步, 否则先读到的事件未完成会污染计时。"""
    torch.cuda.set_device(i)
    si = torch.randn(nbytes // 4, dtype=torch.float32, device=i)
    di = torch.empty(nbytes // 4, dtype=torch.float32, device=i)
    torch.cuda.set_device(j)
    sj = torch.randn(nbytes // 4, dtype=torch.float32, device=j)
    dj = torch.empty(nbytes // 4, dtype=torch.float32, device=j)

    for _ in range(warmup):
        dj.copy_(si, non_blocking=True)
        di.copy_(sj, non_blocking=True)
    torch.cuda.synchronize(i)
    torch.cuda.synchronize(j)

    torch.cuda.set_device(i)
    st_i = torch.cuda.Stream()
    s_i = torch.cuda.Event(enable_timing=True)
    e_i = torch.cuda.Event(enable_timing=True)
    torch.cuda.set_device(j)
    st_j = torch.cuda.Stream()
    s_j = torch.cuda.Event(enable_timing=True)
    e_j = torch.cuda.Event(enable_timing=True)

    with torch.cuda.stream(st_i):
        s_i.record()
        for _ in range(iters):
            di.copy_(sj, non_blocking=True)   # j -> i
        e_i.record()
    with torch.cuda.stream(st_j):
        s_j.record()
        for _ in range(iters):
            dj.copy_(si, non_blocking=True)   # i -> j
        e_j.record()

    torch.cuda.synchronize(i)
    torch.cuda.synchronize(j)

    ti = s_i.elapsed_time(e_i) / 1000.0 / iters
    tj = s_j.elapsed_time(e_j) / 1000.0 / iters
    sec = max(ti, tj)
    return 2 * nbytes / sec / 1e9


def main():
    ng = torch.cuda.device_count()
    n = enable_all(ng)
    print(f"已启用 {n} 条 P2P 链路。")
    pairs = [(i, j) for i in range(ng) for j in range(ng)
             if i < j and torch.cuda.can_device_access_peer(i, j)]
    if not pairs:
        print("No peer-access pairs detected. P2P 将回退到 host staging (经 CPU 中转), 速度会显著下降。")
        print("请检查 BIOS 中 ACS / PCIe 拓扑设置; NCCL 流量会改走 CPU。")
        return

    print("=== 1 GiB P2P 每对 (顺序双向) + 并发双向 ===")
    print(f"{'pair':>7} | {'1GiB i->j':>11} | {'1GiB j->i':>11} | {'bidir GB/s':>11}")
    for (i, j) in pairs:
        a = measure_copy(i, j, 1 << 30)
        b = measure_copy(j, i, 1 << 30)
        c = measure_bidir(i, j, 1 << 30)
        print(f"{str(i)+'->'+str(j):>7} | {a:>11.2f} | {b:>11.2f} | {c:>11.2f}", flush=True)

    i, j = pairs[0]
    print(f"\n=== 尺寸扫描 GPU{i}->GPU{j} (单方向) ===")
    print(f"{'size':>10} | {'GB/s':>8}")
    for exp in range(20, 31):  # 1 MiB .. 1 GiB
        nbytes = 1 << exp
        bw = measure_copy(i, j, nbytes, iters=30)
        print(f"{fmt(nbytes):>10} | {bw:>8.2f}", flush=True)


if __name__ == "__main__":
    main()

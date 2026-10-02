#!/usr/bin/env python3
"""P2P 诊断脚本：解释 ~13.2 GB/s 的来源，并判定双向为何不叠加。

七个对照（结论导向）：
  A. PCIe 链路代际/宽度          -> 确认每条链路上限的来源
  B. 单卡 pinned H2D / D2H       -> 一条 x16 链路的实际上限（与 P2P 数字互证）
  C. 直接 P2P 单向 vs 双向        -> 双向是否翻倍（两端分别报速率）
  D. 4 对并发单向聚合             -> 判定"每链路独立"还是"全局单一瓶颈"
  E. 直接 P2P vs host-staged      -> 确认是否真的走了 P2P（而非经 CPU 中转）
  F. 双线程双向（两个 CPU 线程）   -> 排除单进程多流排布问题
  G. 两对各自双向并发             -> 终审：单链路是"总量 13.2"还是"每向 13.2"
"""
import subprocess
import threading
import time

import torch

from p2putil import enable_all


def sync_all():
    """逐个设备同步（torch.cuda.synchronize() 默认只同步当前设备）。"""
    for d in range(torch.cuda.device_count()):
        torch.cuda.synchronize(d)


def pcie_info():
    q = "index,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max"
    try:
        out = subprocess.run(
            ["nvidia-smi", f"--query-gpu={q}", "--format=csv"],
            capture_output=True, text=True, check=True,
        ).stdout
        print(out.strip())
    except Exception as e:  # noqa: BLE001
        print(f"[warn] nvidia-smi query failed: {e}")


def timeit(fn, dev, iters):
    """在 dev 上测量 fn() 单次耗时（秒）。单设备场景，同步 dev 即可。"""
    torch.cuda.set_device(dev)
    st = torch.cuda.Stream()
    s = torch.cuda.Event(enable_timing=True)
    e = torch.cuda.Event(enable_timing=True)
    with torch.cuda.stream(st):
        s.record()
        for _ in range(iters):
            fn()
        e.record()
    torch.cuda.synchronize(dev)
    return s.elapsed_time(e) / 1000.0 / iters


def host_bw(dev, nbytes, iters=20):
    """pinned 主机内存 <-> GPU 的 H2D / D2H 带宽 (GB/s)。"""
    torch.cuda.set_device(dev)
    h = torch.empty(nbytes // 4, dtype=torch.float32, pin_memory=True)
    d = torch.empty(nbytes // 4, dtype=torch.float32, device=dev)
    h2d = timeit(lambda: d.copy_(h, non_blocking=True), dev, iters)
    d2h = timeit(lambda: h.copy_(d, non_blocking=True), dev, iters)
    return nbytes / h2d / 1e9, nbytes / d2h / 1e9


def p2p_uni(a, b, nbytes, iters=20):
    """a -> b 直接 P2P 单向带宽 (GB/s)。"""
    torch.cuda.set_device(a)
    src = torch.randn(nbytes // 4, dtype=torch.float32, device=a)
    torch.cuda.set_device(b)
    dst = torch.empty(nbytes // 4, dtype=torch.float32, device=b)
    sec = timeit(lambda: dst.copy_(src, non_blocking=True), b, iters)
    return nbytes / sec / 1e9


def p2p_bidir(i, j, nbytes, iters=20):
    """i <-> j 双向并发（两个设备各自的流）：返回 (i->j 速率, j->i 速率, 聚合速率) GB/s。"""
    torch.cuda.set_device(i)
    si = torch.randn(nbytes // 4, dtype=torch.float32, device=i)
    di = torch.empty(nbytes // 4, dtype=torch.float32, device=i)
    torch.cuda.set_device(j)
    sj = torch.randn(nbytes // 4, dtype=torch.float32, device=j)
    dj = torch.empty(nbytes // 4, dtype=torch.float32, device=j)
    for _ in range(5):
        dj.copy_(si, non_blocking=True)
        di.copy_(sj, non_blocking=True)
    sync_all()

    torch.cuda.set_device(i)
    st_i = torch.cuda.Stream()
    es_i = torch.cuda.Event(enable_timing=True)
    ee_i = torch.cuda.Event(enable_timing=True)
    torch.cuda.set_device(j)
    st_j = torch.cuda.Stream()
    es_j = torch.cuda.Event(enable_timing=True)
    ee_j = torch.cuda.Event(enable_timing=True)

    with torch.cuda.stream(st_i):
        es_i.record()
        for _ in range(iters):
            di.copy_(sj, non_blocking=True)   # j -> i
        ee_i.record()
    with torch.cuda.stream(st_j):
        es_j.record()
        for _ in range(iters):
            dj.copy_(si, non_blocking=True)   # i -> j
        ee_j.record()
    sync_all()

    ti = es_i.elapsed_time(ee_i) / 1000.0 / iters   # j->i
    tj = es_j.elapsed_time(ee_j) / 1000.0 / iters   # i->j
    return (nbytes / tj / 1e9, nbytes / ti / 1e9, 2 * nbytes / max(ti, tj) / 1e9)


def p2p_bidir_threads(i, j, nbytes, iters=10):
    """双线程双向：两个 CPU 线程各负责一个方向，排除单进程多流排布的影响。"""
    torch.cuda.set_device(i)
    si = torch.randn(nbytes // 4, dtype=torch.float32, device=i)
    di = torch.empty(nbytes // 4, dtype=torch.float32, device=i)
    torch.cuda.set_device(j)
    sj = torch.randn(nbytes // 4, dtype=torch.float32, device=j)
    dj = torch.empty(nbytes // 4, dtype=torch.float32, device=j)
    for _ in range(3):
        dj.copy_(si)
        di.copy_(sj)
    sync_all()

    barrier = threading.Barrier(2)
    result = {}

    def run(dev, dst, src, key):
        torch.cuda.set_device(dev)
        for _ in range(2):
            dst.copy_(src, non_blocking=True)
        torch.cuda.synchronize(dev)
        barrier.wait()
        t0 = time.perf_counter()
        for _ in range(iters):
            dst.copy_(src, non_blocking=True)
        torch.cuda.synchronize(dev)
        result[key] = (time.perf_counter() - t0) / iters

    t1 = threading.Thread(target=run, args=(j, dj, si, "ij"))   # i -> j
    t2 = threading.Thread(target=run, args=(i, di, sj, "ji"))   # j -> i
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    tij, tji = result["ij"], result["ji"]
    return (nbytes / tij / 1e9, nbytes / tji / 1e9, 2 * nbytes / max(tij, tji) / 1e9)


def p2p_staged(i, j, nbytes, iters=10):
    """经 pinned 主机内存中转的 GPU i -> GPU j 带宽 (GB/s, 近似值)。"""
    torch.cuda.set_device(i)
    src = torch.randn(nbytes // 4, dtype=torch.float32, device=i)
    torch.cuda.set_device(j)
    dst = torch.empty(nbytes // 4, dtype=torch.float32, device=j)
    buf = torch.empty(nbytes // 4, dtype=torch.float32, pin_memory=True)
    buf.copy_(src)
    dst.copy_(buf)
    sync_all()

    t0 = time.perf_counter()
    for _ in range(iters):
        buf.copy_(src)   # D2H (blocking)
        dst.copy_(buf)   # H2D (blocking)
    t1 = time.perf_counter()
    return nbytes / ((t1 - t0) / iters) / 1e9


def concurrent_pairs(pairs, nbytes, iters=20):
    """多对同时单向搬运的聚合带宽 (GB/s)。"""
    todo = []
    for (a, b) in pairs:
        torch.cuda.set_device(a)
        s = torch.randn(nbytes // 4, dtype=torch.float32, device=a)
        torch.cuda.set_device(b)
        d = torch.empty(nbytes // 4, dtype=torch.float32, device=b)
        st = torch.cuda.Stream()
        es = torch.cuda.Event(enable_timing=True)
        ee = torch.cuda.Event(enable_timing=True)
        todo.append((a, b, s, d, st, es, ee))

    for (_a, _b, s, d, st, _es, _ee) in todo:
        with torch.cuda.stream(st):
            d.copy_(s, non_blocking=True)
    sync_all()

    for (_a, _b, s, d, st, es, ee) in todo:
        with torch.cuda.stream(st):
            es.record()
            for _ in range(iters):
                d.copy_(s, non_blocking=True)
            ee.record()
    sync_all()

    elapsed = max(es.elapsed_time(ee) for (*_, es, ee) in todo) / 1000.0 / iters
    return len(pairs) * nbytes / elapsed / 1e9


def bidir_multi_pairs(pairs, nbytes, iters=20):
    """多对各自双向并发。返回聚合带宽 (GB/s)。
    若每物理链路"总量 13.2" -> 聚合约 N_pairs×13.2; 若"每向 13.2"(全双工) -> 约 2×N_pairs×13.2。"""
    tasks = []   # (dst_dev, dst, src, stream, es, ee)
    for (i, j) in pairs:
        torch.cuda.set_device(i)
        si = torch.randn(nbytes // 4, dtype=torch.float32, device=i)
        di = torch.empty(nbytes // 4, dtype=torch.float32, device=i)
        torch.cuda.set_device(j)
        sj = torch.randn(nbytes // 4, dtype=torch.float32, device=j)
        dj = torch.empty(nbytes // 4, dtype=torch.float32, device=j)
        # 方向 j -> i
        torch.cuda.set_device(i)
        st1 = torch.cuda.Stream()
        es1 = torch.cuda.Event(enable_timing=True)
        ee1 = torch.cuda.Event(enable_timing=True)
        tasks.append((i, di, sj, st1, es1, ee1))
        # 方向 i -> j
        torch.cuda.set_device(j)
        st2 = torch.cuda.Stream()
        es2 = torch.cuda.Event(enable_timing=True)
        ee2 = torch.cuda.Event(enable_timing=True)
        tasks.append((j, dj, si, st2, es2, ee2))

    for (_d, dst, src, st, _es, _ee) in tasks:
        with torch.cuda.stream(st):
            dst.copy_(src, non_blocking=True)
    sync_all()

    for (_d, dst, src, st, es, ee) in tasks:
        with torch.cuda.stream(st):
            es.record()
            for _ in range(iters):
                dst.copy_(src, non_blocking=True)
            ee.record()
    sync_all()

    elapsed = max(es.elapsed_time(ee) for (*_, es, ee) in tasks) / 1000.0 / iters
    return len(tasks) * nbytes / elapsed / 1e9


def main():
    ng = torch.cuda.device_count()
    enable_all(ng)
    GB = 1 << 30
    print(f"Detected {ng} GPU(s), 单次搬运 1 GiB\n")

    print("=== A. PCIe 链路 (代际/宽度) ===")
    pcie_info()

    print("\n=== B. 单卡 pinned H2D / D2H (1 GiB) ===")
    print(f"{'gpu':>4} | {'H2D GB/s':>9} | {'D2H GB/s':>9}")
    for d in range(ng):
        h2d, d2h = host_bw(d, GB)
        print(f"{d:>4} | {h2d:>9.2f} | {d2h:>9.2f}")

    pix = (0, 1) if ng >= 2 else None
    node = (0, 2) if ng >= 3 else None

    print("\n=== C. 直接 P2P 单向 vs 双向 (1 GiB, 两个设备各自的流) ===")
    print(f"{'pair':>7} | {'uni GB/s':>9} | {'A->B':>7} | {'B->A':>7} | {'bidir agg':>10}")
    for p in (pix, node):
        if not p:
            continue
        i, j = p
        u = p2p_uni(i, j, GB)
        ra, rb, agg = p2p_bidir(i, j, GB)
        print(f"{str(i)+'->'+str(j):>7} | {u:>9.2f} | {ra:>7.2f} | {rb:>7.2f} | {agg:>10.2f}")

    print("\n=== D. 4 对并发单向 (每对 1 GiB) ===")
    if ng >= 8:
        pairs4 = [(0, 1), (2, 3), (4, 5), (6, 7)]
    else:
        pairs4 = [(k, k + 1) for k in range(0, ng - 1, 2)]
    agg4 = concurrent_pairs(pairs4, GB)
    print(f"pairs={pairs4}")
    print(f"聚合带宽 = {agg4:.2f} GB/s  (单对≈13.2; ≈N×13.2 → 每链路独立)")

    print("\n=== E. 直接 P2P vs host-staged (1 GiB) ===")
    if pix:
        i, j = pix
        print(f"GPU{i}->GPU{j}: 直接 P2P {p2p_uni(i, j, GB):.2f} GB/s | "
              f"host-staged {p2p_staged(i, j, GB):.2f} GB/s")

    print("\n=== F. 双线程双向 (1 GiB, 每方向一个 CPU 线程) ===")
    if pix:
        i, j = pix
        ra, rb, agg = p2p_bidir_threads(i, j, GB)
        print(f"GPU{i}<->GPU{j}: A->B {ra:.2f} | B->A {rb:.2f} | 聚合 {agg:.2f} GB/s")
        print("判读: 聚合≈2×单向 → 之前只是单进程多流没并发; 聚合≈单向 → 双向确实不叠加。")

    print("\n=== G. 两对各自双向并发 (终审) ===")
    if ng >= 4:
        pairs2 = [pix, (2, 3)]
        aggb = bidir_multi_pairs(pairs2, GB)
        print(f"pairs={pairs2} 各跑双向, 共 4 个方向")
        print(f"聚合带宽 = {aggb:.2f} GB/s")
        print(f"判读: ≈{2*13.2:.0f}(=2×13.2) → 每物理链路总量≈13.2, 非全双工; "
              f"≈{4*13.2:.0f}(=4×13.2) → 每向各 13.2(全双工), C 段的串行化是软件行为。")


if __name__ == "__main__":
    main()

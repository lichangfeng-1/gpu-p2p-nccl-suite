#!/usr/bin/env python3
"""P2P 可达性检查：打印可达矩阵、显式启用 P2P 链路、给出判读。
注意: torch.cuda 没有公开的 enable_peer_access; 这里用 p2putil（ctypes 调 libcudart）
显式启用, 并以跨设备 copy_ 的隐式启用兜底。
判据以 can_device_access_peer 的可达性矩阵为准（这是 P2P 能否可用的 ground truth）。
"""
import torch

from p2putil import cudart, enable_p2p


def main():
    ng = torch.cuda.device_count()
    print(f"Detected {ng} GPU(s)\n")

    print("Peer-access matrix  (row -> col: 'Y' = row 设备可直接读写 col 设备显存):")
    print("src\\dst".ljust(8) + "".join(f"{j:>4}" for j in range(ng)))
    reachable = 0
    for i in range(ng):
        row = f"{i:<8}"
        for j in range(ng):
            if i == j:
                row += "  --"
                continue
            try:
                ok = torch.cuda.can_device_access_peer(i, j)
            except Exception:
                ok = False
            if ok:
                reachable += 1
            row += "   Y" if ok else "   N"
        print(row)

    total = ng * (ng - 1)

    if cudart():
        print("\n显式启用所有可达 P2P 链路 (cudaDeviceEnablePeerAccess):")
        for i in range(ng):
            for j in range(ng):
                if i == j or not torch.cuda.can_device_access_peer(i, j):
                    continue
                rc = enable_p2p(i, j)
                if rc not in (0, 704):
                    print(f"  enable {i}->{j} 返回码 {rc} (705=平台不支持, 将走 PyTorch 隐式启用)")
    else:
        print("\n[提示] 未找到 libcudart, 跳过显式启用; 跨设备 copy_ 会由 PyTorch 隐式启用。")

    print(f"\n摘要: {reachable}/{total} 条 P2P 链路可达")
    if reachable == total:
        print("判读: 全连通 — P2P mesh 完整, NCCL 可全程走 PCIe P2P, 无需中转。")
    elif reachable > 0:
        print("判读: 部分连通 — 不可达的 GPU 对会回退 CPU 中转, 需进 BIOS 关闭 ACS 后重测。")
    else:
        print("判读: 全不可达 — 必须进 BIOS 关闭 ACS / IOMMU 后重测, 否则 P2P 全走 CPU。")


if __name__ == "__main__":
    main()

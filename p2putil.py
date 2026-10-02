#!/usr/bin/env python3
"""P2P 辅助模块。
torch.cuda 只提供 can_device_access_peer()，没有公开的 enable_peer_access()，
因此这里用 ctypes 直接调用 libcudart 的 cudaDeviceEnablePeerAccess 显式启用 P2P 通路。
注: 即使此步不可用，PyTorch 的跨设备 copy_() 也会在内部启用 peer access 兜底。
"""
import ctypes
import glob
import os

import torch

_CUDART = None


def _extra_cands():
    """Debian/Ubuntu 多架构目录与 ldconfig 注册项。
    原来只猜 /usr/local/cuda*/lib64，那是 CUDA runfile 的布局；apt 装的 libcudart
    落在 /usr/lib/<arch>-linux-gnu，容器外跑原生模式时必须能找到，否则整轮退化成
    "依赖 PyTorch 隐式启用"，P2P 矩阵就少了显式启用这一路证据。"""
    out = []
    try:
        import platform
        mach = platform.machine()
        out += glob.glob(f"/usr/lib/{mach}-linux-gnu/libcudart.so*")
        out += glob.glob(f"/usr/lib/{mach}-linux-gnu/nvidia/libcudart.so*")
    except Exception:
        pass
    try:
        from ctypes.util import find_library
        f = find_library("cudart")
        if f:
            out.append(f)
    except Exception:
        pass
    return out


def cudart():
    """惰性加载 libcudart：成功返回 CDLL，失败返回 False。"""
    global _CUDART
    if _CUDART is not None:
        return _CUDART

    cands = ["libcudart.so", "libcudart.so.12", "libcudart.so.11.0"]
    try:
        cands += glob.glob(os.path.join(os.path.dirname(torch.__file__), "lib", "libcudart*.so*"))
    except Exception:
        pass
    cands += glob.glob("/usr/local/cuda/lib64/libcudart.so*")
    cands += glob.glob("/usr/local/cuda*/lib64/libcudart.so*")
    cands += _extra_cands()

    for c in cands:
        try:
            lib = ctypes.CDLL(c)
            # 若加载到的不是真正的 libcudart，取符号会抛 AttributeError，一并跳过
            lib.cudaDeviceEnablePeerAccess.argtypes = [ctypes.c_int, ctypes.c_uint]
            lib.cudaDeviceEnablePeerAccess.restype = ctypes.c_int
            _CUDART = lib
            break
        except (OSError, AttributeError):
            continue
    else:
        _CUDART = False
    return _CUDART


def enable_p2p(dev, peer):
    """使 dev 设备可直连 peer 设备显存。
    返回: 0=成功 / 704=已启用 / 705=平台不支持 / None=无法显式启用(依赖 PyTorch 兜底)。"""
    torch.cuda.set_device(dev)
    torch.empty(1, device=dev)  # 确保该设备的 CUDA context 已创建
    lib = cudart()
    if not lib:
        return None
    return lib.cudaDeviceEnablePeerAccess(peer, 0)


def enable_all(ng=None):
    """启用全部可用的 P2P 链路，返回显式启用成功的链路数。"""
    ng = torch.cuda.device_count() if ng is None else ng
    n = 0
    for i in range(ng):
        for j in range(ng):
            if i == j:
                continue
            try:
                if not torch.cuda.can_device_access_peer(i, j):
                    continue
            except Exception:
                continue
            if enable_p2p(i, j) in (0, 704, None):
                n += 1
    return n

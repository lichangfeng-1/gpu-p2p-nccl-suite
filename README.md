# GPU P2P / NCCL 体检套件（多发行版 · 国内网络优先）

在 Linux 服务器上检查并测量 GPU 之间的 P2P 通路：可达矩阵、单向/双向带宽、1 GiB 大文件、
多流并发、NCCL all_reduce 总线带宽，外加 PCIe 拓扑与链路降速诊断。产出**带口径标注、可归档**的结论，
而不是一屏滚过去的数字。Debian / Ubuntu 优先，有容器没容器都能跑。

## 30 秒上手

```bash
bash env-check-v1.sh      # 只读体检：与参考环境逐项对齐了吗，缺什么给什么命令卡
bash run_all-v2.sh        # 体检通过才跑：自动选后端 → 六段测试 → 判读落盘
```

需要：Linux、2 张以上可互访的 NVIDIA 卡、满足下面任一条——
docker + nvidia-container-toolkit / podman + CDI 规格 / 本机 python 里装好 torch 且 CUDA 可用。

## 测什么（六类；日志里是七个段标题，sanity 与 topo 各占一个）

| 段 | 覆盖 | 关键输出 |
|---|---|---|
| sanity + topo | torch/GPU 可见性、`nvidia-smi topo -m` | 卡型、显存、互联矩阵 |
| P2P ACCESS MATRIX | `can_device_access_peer` 逐对判定，并用 ctypes 显式 `cudaDeviceEnablePeerAccess` | `摘要: N/M 条链路可达` ＋ 判读行 |
| NCCL BANDWIDTH | all_reduce（ring），1 KiB ~ 512 MiB | `algbw` / `busbw` |
| P2P BANDWIDTH | 1 GiB 单向、反向、并发双向 ＋ 尺寸扫描 | 每对三列 GB/s |
| MULTI-STREAM | 同一对 GPU 上 1/2/4/8 条流并发 | 聚合带宽随流数变化 |
| DIAGNOSTICS | 链路 gen/width、host-staged 对照、多对并发终审 | 判断"每链路独立"还是"共享上限" |

## 立场：对齐参考环境，不适配任意环境

参考值取自一台 8×T10 服务器（机型 G292-Z20）2026-10-01 实测：

```
Ubuntu 24.04.x LTS | kernel 6.8.x | docker 29.8.0 | driver 580.173.02
8× Tesla T10 16384MiB | SM 7.5 | glibc 2.39 | python 3.12 (dist-packages)
torch 镜像 pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime
```

体检输出三档：

- `ALIGNED` 与参考一致 → 数字可与参考直接比。
- `DRIFT` 能跑但与参考不同 → **结论仍产出，但不可与参考互比**，日志会带上漂移项。
- `BLOCK` 跑不起来 → 给对齐动作，默认不硬跑（`--allow-drift` 才强行继续）。

## 三条后端与降级

`docker → podman → native` 自动降级，`--backend=` 可强制（强制时不做降级询问）。降级前在交互终端会先问一句：
容器与宿主机原生两条路的 CUDA/NCCL 版本不同，结果不可互比，不能悄悄换。非交互环境自动降级并在日志里标注。
要跳过询问直接按降级继续，加 `--yes`（只在 `--backend=auto` 时有意义）。

## 结论怎么读

日志文件（默认 `p2p-suite-时间戳.log`）里这几行是结论：
`P2P_LINKS`、`P2P_VERDICT`、`P2P_MIN_SINGLE_DIR_GBPS`、`P2P_MIN_BIDIR_GBPS`、`NCCL_MAX_BUSBW_GBPS`、`P2P_RESULT`。

| 退出码 | 含义 |
|---|---|
| 0 | 全连通，且六段都没失败段 |
| 1 | 连通性通过但有 `STAGE_FAIL` 段（`PASS_WITH_STAGE_FAILS`：带宽/NCCL 结论残缺） |
| 2 | 用法错误、`TORCH_IMG` 含非法字符、日志不可写 |
| 3 | 跳过未跑（缺文件 / 镜像不在且没开 `--pull` / GPU 被占 / 门禁阻断未放行 / 你选了停） |
| 4 | 没有任何可用后端 |
| 6 | 部分连通（不可达的 GPU 对会回退 CPU 中转） |
| 7 | 全不可达（通常是 BIOS 的 ACS / IOMMU） |
| 8 | 低于你显式设的 `P2P_FLOOR_GBPS` / `NCCL_FLOOR_GBPS` |
| 9 | 日志里没有判读行（多半某段 STAGE_FAIL） |

**跳过不等于通过**：`1`、`3`、`9` 都不是好消息。

体检脚本自己那三个码是另一套（`run_all-v2.sh` 拿它当门禁）：`0`＝OK 或 DRIFT、`4`＝无任何后端、`5`＝有阻断项；
收尾行 `ENV_VERDICT=OK|WARN|INCOMPAT` 与之一一对应。

参考量级（T10 走 PCIe 3.0 x16，单链路理论上限约 15.75 GB/s）：某台 Ubuntu 24.04.5 + 8×T10 实测
56/56 链路全连通、单向下限 13.16 GB/s、双向 13.15、NCCL busbw 11.53。这是**那一台**的数，不是验收线；
要卡下限请显式传阈值，脚本不内置机型经验值。

## 不做什么

- 不装驱动、不改系统源、不写 `/etc/docker/daemon.json`——体检只报告，命令卡给你，执行权在你。
- 不内置任何第三方镜像加速域名。要换入口自己传：`P2P_IMAGE_MIRRORS=`（只换 registry 前缀、不换 tag）、`TORCH_IMG=`。
  `PIP_INDEX_URL` 本仓脚本不消费，只是提醒你：自己 pip 装 torch 时先把它设好。
- 不静默起 10 GiB 级下载：镜像不在时只打 `docker pull` 命令卡，真下由 `--pull` 决定。
- 不抢在役 GPU：卡上有计算进程就跳过并退出码 3。
- 驱动与 CUDA 只报要求不给安装命令（装错驱动会打挂在役机器）；nvidia-container-toolkit 这类轻依赖才给卡。
  容器运行时缺失时推荐用 1Panel 一键装（见 `参考环境对齐清单-v1.md` 第 3 节，含代价说明）。

## 文件

| 文件 | 角色 |
|---|---|
| `run_all-v2.sh` | 入口：门禁 → 后端 → 镜像 → 执行 → 判读落盘 |
| `env-check-v1.sh` | 参考环境对齐体检（只读） |
| `run_suite-inside-v1.sh` | 六段执行体，容器内与宿主机原生共用一份 |
| `p2p_check.py` `p2p_bandwidth.py` `nccl_bandwidth.py` `multistream_p2p.py` `diag_p2p.py` `p2putil.py` | 测试本体 |
| `selftest-v1.sh` | 离线自测（桩化 docker/nvidia-smi/python，不碰 GPU 不联网） |
| `参考环境对齐清单-v1.md` | 给使用者的一页纸：对齐表、命令卡、报错读法 |
| `版本说明.md` | 为什么这么改、与上一版差异、验证状态 |
| `run_all.sh` | 上一代入口，写死 docker 与 `-it`；保留作对照，不再是入口 |

## 依赖与离线复算

测试本体需要 python + torch（CUDA 可用）；容器路径由 `run_all-v2.sh` 拉一个公共 PyTorch 镜像，
本机不必装 torch。已跑过一轮想重新出判读结论（改了阈值、或想把结论再核一遍），不必重跑 GPU：

```bash
OUT=<已有日志> PARSE_ONLY=1 bash run_all-v2.sh   # 只解析不跑卡，绝不截断那份日志
```

贴日志到公开场合前，把 `P2P_HOST=` 那行抹掉（里面是主机名），并留意体检段会带出绝对路径与驱动版本。

## 自测与验证状态

```bash
bash selftest-v1.sh     # 49 条断言：发行版分支、三档判定、后端判定、判读解析五档、参数与早退、
#                       mirror 前缀生效、pull 失败不记成功、OUT 防误覆盖、镜像名注入、floor 无数据、段失败降级
```

已过：`bash -n` 全量、`py_compile`、上述 49 条断言。
**未验**（需要实机）：Debian 与 Ubuntu 真机、podman CDI 路径、原生模式跑通、真实 `docker pull` 行为。

## 许可

Apache License 2.0，见 `LICENSE` 与 `NOTICE`。

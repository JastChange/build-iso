# 代码审查与功能完成度

本文记录对原仓库的审查结论，以及本次重实现后的功能状态。

## 原有实现概况

原仓库已经具备以下基础能力：

- 能解包官方 Ubuntu Server ISO，并通过 `xorriso` 重新封装。
- 能注入 `autoinstall/user-data` 和 `meta-data`。
- 能注入 `extras/` 目录，包括脚本、驱动、密钥、deb、repo。
- 有固定内核配置文件 `kernel.env` 和安装逻辑雏形。
- 有 Mellanox OFED、NVIDIA 驱动安装脚本。
- 有本地 APT 仓库构建脚本。

## 主要问题

| 问题 | 影响 | 处理结果 |
|------|------|----------|
| 驱动在 `post-install.sh` 中安装 | 该阶段不一定运行目标系统最终内核，驱动模块可能编译到错误内核 | 改为 firstboot 统一安装 |
| NVIDIA 使用单独 `nvidia-driver-firstboot.service` | 与整体首次开机清理/重启流程割裂 | 合并为 `iso-firstboot.service` |
| 首次开机后不清理 `/opt/extras` | 驱动包、离线仓库、密钥等残留在目标机 | 新增 `firstboot.sh` 清理 |
| 首次开机后不统一重启 | 驱动模块安装后可能未生效 | 新增 `FIRSTBOOT_REBOOT` 配置 |
| 预装工具列表硬编码在脚本里 | 改工具需要改脚本，易出错 | 新增 `extras/config/packages.list` |
| `download-kernel.sh` 没有下载 common headers | `deb` 模式可能缺少 `linux-headers-<base>` | 已补齐必需包 |
| `patch-kernel-install.sh` 会修改构建脚本 | 旧方案风险高且与当前链路冲突 | 改为兼容入口，只更新 `kernel.env` |
| `build-repo.sh` 生成的 `.gpg` 是 ASCII armor | `signed-by` 期望二进制 keyring 更稳 | 改为同时导出二进制 `.gpg` 和 `.asc` |
| `user-data` 存在乱码注释 | 可读性差 | 已修复中文注释 |
| 构建阶段安装 `openssh-server` 会生成 SSH host keys | 多台目标机可能共享同一组主机密钥 | squashfs 清理阶段删除 host keys，目标机首次启动再生成 |
| 缺少测试 | 关键函数变更无回归保障 | 新增 `tests/run-tests.sh` |

## 重实现后的完成度

| 需求 | 完成度 | 说明 |
|------|--------|------|
| Ubuntu 自动安装 ISO 构建 | 完成 | `build.sh` 是主入口 |
| 镜像内安装工具 | 完成 | `packages.list` 控制预装包 |
| 指定版本内核安装 | 完成 | `kernel.env` + repo/deb/auto 三种模式 |
| 分区由 user-data 指定 | 完成 | 默认 `/dev/sda` GPT 三分区，可直接改 YAML |
| 密钥由 user-data 指定 | 完成 | `authorized_keys` 构建时注入 autoinstall |
| 部分驱动首次开机安装 | 完成 | `iso-firstboot.service` 调用 `firstboot.sh` |
| 安装完成后清理残留 | 完成 | 默认删除 `/opt/extras` 和 firstboot 服务 |
| 清理后重启服务器 | 完成 | 默认 `FIRSTBOOT_REBOOT=true` |
| 中文使用文档 | 完成 | `docs/usage.md` |
| 中文设计文档 | 完成 | `docs/design.md` |

## 仍需真实环境验证的部分

以下能力受环境限制，无法只靠本地静态测试完全验证：

- 使用真实 Ubuntu ISO 完整构建。
- 使用 QEMU 或物理机跑完整 autoinstall。
- Mellanox OFED 和 NVIDIA 驱动在具体硬件上的安装结果。
- 指定内核版本是否存在于当前 Ubuntu 源或本地 repo。

建议在交付前至少做一次 QEMU 自动安装验证；如果目标是物理 GPU/RDMA 服务器，还应在同型号硬件上验证 firstboot 日志和重启后的驱动状态。

# 设计文档

## 目标

项目目标是生成一个可无人值守安装 Ubuntu Server 的 ISO，并满足以下要求：

- 镜像内可预装常用工具和驱动编译依赖。
- 分区、用户、密码、SSH 密钥等安装参数由 `user-data` 控制。
- 可安装指定 ABI 版本的 Ubuntu 内核，并可锁定内核包。
- Mellanox OFED、NVIDIA 等依赖真实运行内核的驱动在目标系统首次开机后安装。
- 首次开机任务完成后清理构建/安装残留，并按配置重启服务器。

## 总体架构

```text
官方 Ubuntu Server ISO
        |
        v
build.sh
        |
        +-- customize-squashfs.sh
        |       +-- 读取 extras/config/packages.list
        |       +-- chroot 安装预装工具和编译依赖
        |
        +-- 注入 autoinstall/user-data 与 meta-data
        +-- 注入 extras/
        +-- 修改 GRUB 自动安装入口
        +-- xorriso 重新封装 ISO
        |
        v
定制 autoinstall ISO
```

运行时：

```text
ISO 启动
  |
  v
Subiquity 读取 /cdrom/autoinstall/user-data
  |
  v
安装目标系统，按 user-data 分区和创建用户
  |
  v
late-commands
  |
  +-- cp /cdrom/extras -> /target/opt/extras
  +-- curtin in-target -- /opt/extras/scripts/post-install.sh
          |
          +-- 读取 kernel.env
          +-- 安装/锁定指定内核
          +-- 注册 iso-firstboot.service
  |
  v
目标系统首次启动
  |
  v
iso-firstboot.service
  |
  +-- firstboot.sh
          |
          +-- 读取 firstboot.env
          +-- 安装 Mellanox OFED
          +-- 安装 NVIDIA 驱动
          +-- 清理 /opt/extras 和 systemd 服务
          +-- 按配置重启
```

## 目录职责

| 路径 | 职责 |
|------|------|
| `ubuntu-autoinstall/build.sh` | 主构建入口，负责解包、注入、改 GRUB、封装 ISO |
| `ubuntu-autoinstall/customize-squashfs.sh` | 定制目标系统镜像层，安装工具包 |
| `ubuntu-autoinstall/build-repo.sh` | 生成本地 APT 仓库索引和签名 |
| `ubuntu-autoinstall/user-data` | Subiquity autoinstall 配置 |
| `ubuntu-autoinstall/extras/config/packages.list` | 构建时预装 apt 包列表 |
| `ubuntu-autoinstall/extras/config/kernel.env` | 固定内核配置 |
| `ubuntu-autoinstall/extras/config/firstboot.env` | 首次开机清理和重启配置 |
| `ubuntu-autoinstall/extras/lib/iso-functions.sh` | 安装阶段共享函数 |
| `ubuntu-autoinstall/extras/scripts/post-install.sh` | 安装阶段目标系统 chroot 内执行 |
| `ubuntu-autoinstall/extras/scripts/firstboot.sh` | 目标系统首次真实启动后执行 |
| `ubuntu-autoinstall/extras/drivers/` | 离线驱动安装包 |
| `ubuntu-autoinstall/extras/repo/` | 本地离线 APT 仓库 |
| `ubuntu-autoinstall/extras/debs/` | 直接 dpkg 安装的离线 deb 包 |

## 关键设计决策

### 1. 内核安装放在 post-install 阶段

内核安装需要在目标系统上下文中生成 initramfs、更新 grub，并写入目标系统的 dpkg 数据库。因此它由 `post-install.sh` 在 `curtin in-target` 环境中完成，而不是在构建机或安装器环境中完成。

### 2. 驱动安装放在 firstboot 阶段

Mellanox OFED 和 NVIDIA 驱动通常会编译当前运行内核的模块。安装器 chroot 阶段的 `uname -r` 可能仍是安装器内核，不一定是目标系统最终内核。因此驱动统一推迟到目标系统第一次启动后执行。

### 3. 配置与实现分离

可变内容放在 `extras/config/`：

- `packages.list` 控制预装工具。
- `kernel.env` 控制固定内核。
- `firstboot.env` 控制首次开机清理和重启。

脚本只实现流程，避免为了改包列表或内核版本去改脚本。

### 4. 本地 repo 优先于散装 deb

固定内核推荐使用 `extras/repo`，因为 apt 可以处理依赖关系、Release 元数据和签名。`extras/debs` 只适合包和依赖已经准备完整的场景。

### 5. 首次开机任务必须可重复保护

`iso-firstboot.service` 使用：

```ini
ConditionPathExists=!/var/lib/ubuntu-autoinstall/firstboot.done
```

`firstboot.sh` 成功后写入 done 文件、禁用并删除服务文件，避免重复安装驱动。

### 6. 清理策略默认开启

默认 `CLEANUP_EXTRAS=true`，首次开机完成后删除 `/opt/extras`，避免驱动包、离线仓库、密钥等残留在目标机。日志保留在：

- `/var/log/post-install.log`
- `/var/log/ubuntu-autoinstall-firstboot.log`
- `/var/log/mlnx-ofed-install.log`
- `/var/log/nvidia-install.log`
- `/var/log/ubuntu-autoinstall-debug/`

构建阶段还会从 squashfs 中清理 SSH host keys 和 machine-id，避免多台通过同一 ISO 安装的机器共享主机密钥或机器标识。

### 7. 驱动失败调试设计

驱动安装横跨 ISO 构建、目标系统 autoinstall、首次真实启动和厂商安装器四层。为了定位失败边界，firstboot 阶段默认启用调试采集：

- `firstboot.sh` 写入系统快照、驱动包列表、内核 headers、DKMS、PCI 设备、Secure Boot、网络和磁盘空间信息。
- `install-mlnx.sh` 写入 OFED 包目标发行版和当前系统发行版；如果包名是 `ubuntu24.04` 但目标系统是 `ubuntu22.04`，日志会明确写出警告。
- Mellanox 默认使用 `MLNX_INSTALL_PROFILE=basic`，优先安装基础网卡/RDMA 功能，避免默认安装 OpenMPI、UCX、SHARP、HCOLL 等非必需组件扩大冲突面；安装器固定追加 `--add-kernel-support --skip-distro-check --force --enable-opensm`。
- 驱动安装默认使用 `DRIVER_OFFLINE_MODE=true`，首次开机阶段不会执行 `apt-get update/install`；所有驱动依赖必须在 ISO 构建阶段通过 `packages.list` 或 `extras/repo` 预置到目标系统。
- Mellanox 失败时生成 `mlnx-ofed-artifacts/failure-summary.txt`，直接汇总 `*.debinstall.log`、`dpkg --audit` 和 `apt-get check`。
- `install-nvidia.sh` 写入 NVIDIA installer 版本、GPU PCI 信息、nouveau 状态、Secure Boot 状态、headers 和 DKMS 状态；安装器固定使用 `-s --dkms`，通过 DKMS 管理内核模块。
- 三个脚本都会在 `FIRSTBOOT_DEBUG=true` 时写入 shell trace。
- 厂商安装器失败时会归档安装器日志、`dmesg` 和 `dkms status`。

驱动失败时默认执行调试友好的策略：

- 保留 `/opt/extras`，避免驱动包和脚本被删除。
- 不自动重启，避免现场状态被重置。
- 不写入 `firstboot.done`，便于排查后重跑。
- 保留 `iso-firstboot.service`，便于手动触发或下次启动再次执行。

## 错误处理策略

| 阶段 | 策略 |
|------|------|
| 构建依赖缺失 | `build.sh` 尝试安装缺失工具 |
| 源 ISO 缺失 | 直接失败 |
| user-data YAML 错误 | 直接失败 |
| 指定内核安装失败 | 直接失败，避免安装出错误内核 |
| 驱动安装失败 | 默认记录失败、保留现场、不自动重启；可用 `DRIVER_FAILURE_POLICY=fail` 改成失败即停 |

## 测试策略

仓库提供 `tests/run-tests.sh`，覆盖不依赖 root 和 ISO 的关键逻辑：

- 内核 ABI 归一化。
- 内核包名计算。
- firstboot systemd 服务生成。

脚本语法通过 `bash -n` 检查。完整 ISO 构建和 QEMU 安装验证需要 Ubuntu 构建机、root 权限和源 ISO。

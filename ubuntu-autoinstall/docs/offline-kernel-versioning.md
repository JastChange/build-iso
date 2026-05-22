# 固定内核版本与离线安装

固定内核由 `extras/config/kernel.env` 和 `extras/scripts/post-install.sh` 实现。该逻辑在目标系统 chroot 内运行，能正确写入目标系统 dpkg 数据库、生成 initramfs、更新 grub，并把 GRUB 默认启动项固定到目标内核。

## 配置文件

编辑：

```bash
ubuntu-autoinstall/extras/config/kernel.env
```

默认配置：

```bash
KERNEL_VERSION=""
KERNEL_FLAVOR="generic"
INSTALL_MODE="auto"
KERNEL_HOLD="true"
```

含义：

| 变量 | 说明 |
|------|------|
| `KERNEL_VERSION` | 目标 ABI，可写 `5.15.0-164` 或 `5.15.0-164-generic` |
| `KERNEL_FLAVOR` | 内核 flavor，通常为 `generic` |
| `INSTALL_MODE` | `repo`、`deb` 或 `auto` |
| `KERNEL_HOLD` | 安装后是否 `apt-mark hold` |

`KERNEL_VERSION` 留空时跳过固定内核安装。

## 需要准备的内核包

必需包：

```text
linux-headers-<base>
linux-headers-<abi>
linux-modules-<abi>
linux-image-<abi>
```

可选包：

```text
linux-modules-extra-<abi>
```

以 `5.15.0-164-generic` 为例：

```text
linux-headers-5.15.0-164
linux-headers-5.15.0-164-generic
linux-modules-5.15.0-164-generic
linux-image-5.15.0-164-generic
linux-modules-extra-5.15.0-164-generic
```

## 推荐方式：本地 repo

下载目标内核包：

```bash
./scripts/download-kernel.sh 5.15.0-164 ./kernel-debs
```

放入 repo：

```bash
mkdir -p ubuntu-autoinstall/extras/repo/pool
cp ./kernel-debs/*.deb ubuntu-autoinstall/extras/repo/pool/
```

生成索引和签名：

```bash
bash ubuntu-autoinstall/build-repo.sh
```

配置 `kernel.env`：

```bash
KERNEL_VERSION="5.15.0-164"
KERNEL_FLAVOR="generic"
INSTALL_MODE="repo"
KERNEL_HOLD="true"
```

构建 ISO：

```bash
sudo bash ubuntu-autoinstall/build.sh
```

## 直接 deb 模式

如果已经准备齐全所有必需包和依赖，可以使用：

```bash
KERNEL_VERSION="5.15.0-164"
INSTALL_MODE="deb"
KERNEL_HOLD="true"
```

把 deb 放入：

```bash
ubuntu-autoinstall/extras/debs/
```

注意：`deb` 模式不会自动解决未提供的远程依赖。若 `dpkg -i` 失败且没有可用本地 repo，安装会失败。

## auto 模式

`auto` 模式顺序：

1. 使用 `extras/repo`。
2. 回退 `extras/debs`。
3. 回退系统 APT 源。

适用于安装现场允许联网，或者希望同一份配置兼容离线/在线环境的场景。

## 安装阶段行为

`user-data` 的 `late-commands` 会执行：

```bash
curtin in-target --target=/target -- bash /opt/extras/scripts/post-install.sh
```

`post-install.sh` 会：

1. 读取 `/opt/extras/config/kernel.env`。
2. 按 `INSTALL_MODE` 配置本地 repo 或 deb。
3. 安装目标内核包。
4. 根据 `KERNEL_HOLD` 锁定已安装的内核包。
5. 写入 `/etc/default/grub` 的 `GRUB_DEFAULT`，指向 `Advanced options for Ubuntu>Ubuntu, with Linux <目标内核 ABI>`。
6. 执行 `update-grub`。
7. 注册 `iso-firstboot.service`，让驱动在首次真实启动后安装。

驱动不在这个阶段安装，避免编译到安装器内核。

目标系统第一次启动后，`firstboot.sh` 会在驱动安装前检查 `uname -r`。如果当前运行内核不是 `kernel.env` 指定的目标内核，会写入 `/var/lib/ubuntu-autoinstall/kernel-mismatch.log` 并停止，不安装 NVIDIA 或 Mellanox 驱动。

## 验证

目标机安装并完成首次开机任务后执行：

```bash
uname -r
dpkg -l | grep '^ii  linux-'
apt-mark showhold | grep '^linux-' || true
cat /var/log/post-install.log
cat /var/log/ubuntu-autoinstall-firstboot.log
ls -lah /var/log/ubuntu-autoinstall-debug/
```

如果 `uname -r` 仍不是目标内核，先确认：

- `kernel.env` 是否已写入非空 `KERNEL_VERSION`。
- `extras/repo/Packages` 或 `extras/debs/*.deb` 是否在 ISO 中。
- `/var/log/post-install.log` 中是否出现内核安装错误。
- `/etc/default/grub` 中 `GRUB_DEFAULT` 是否指向目标内核。
- `/var/lib/ubuntu-autoinstall/kernel-mismatch.log` 是否记录了 firstboot 阻止驱动安装。

如果内核正确但驱动失败，优先查看：

- `/var/lib/ubuntu-autoinstall/driver-failures.log`
- `/var/log/mlnx-ofed-install.log`
- `/var/log/nvidia-install.log`
- `/var/log/ubuntu-autoinstall-debug/mlnx-ofed-system.txt`
- `/var/log/ubuntu-autoinstall-debug/nvidia-system.txt`

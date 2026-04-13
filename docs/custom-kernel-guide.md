# 指定内核版本离线安装指南

## 方案概述

本项目支持三种方式指定内核版本：

1. **方式一：在线安装指定内核**（构建机需联网）- 推荐
2. **方式二：完全离线安装**（使用本地 APT 仓库）
3. **方式三：deb 包直接替换**（最简单，适合特定版本）

---

## 方式一：在线安装指定内核（推荐）

### 适用场景
- 构建机可以联网
- 需要安装官方仓库中的特定内核版本
- 最简单可靠的方式

### 操作步骤

1. **修改 `customize-squashfs.sh`**

在 `PREINSTALL_PACKAGES` 数组后面添加内核安装命令：

```bash
# 在 PREINSTALL_PACKAGES 安装完成后，添加指定内核版本
# 例如：安装 5.15.0-105-generic 内核

step "安装指定版本内核"
TARGET_KERNEL="5.15.0-105-generic"

chroot "${SQUASHFS_ROOT}" bash -c "
  export DEBIAN_FRONTEND=noninteractive
  
  # 更新包索引
  apt-get update -q
  
  # 安装指定版本内核（会自动安装对应的 headers 和 modules）
  apt-get install -y -q \\
    linux-image-${TARGET_KERNEL} \\
    linux-headers-${TARGET_KERNEL} \\
    linux-modules-${TARGET_KERNEL}
  
  # 验证安装
  echo '[INFO] 已安装内核版本：'
  ls -la /boot/vmlinuz-*
" 2>&1 | tee -a "${LOG}"

ok "内核 ${TARGET_KERNEL} 安装完成"
```

2. **查看可用内核版本**

```bash
# 在 Ubuntu 系统上查看可安装的内核版本
apt-cache search linux-image-5.15.0 | grep generic

# 输出示例：
# linux-image-5.15.0-100-generic - Signed kernel image generic
# linux-image-5.15.0-105-generic - Signed kernel image generic
# linux-image-5.15.0-107-generic - Signed kernel image generic
```

3. **构建 ISO**

```bash
cd ubuntu-autoinstall
sudo bash build.sh
```

---

## 方式二：完全离线安装（deb 包）

### 适用场景
- 构建机完全离线
- 需要精确控制内核版本
- 多机部署相同环境

### 操作步骤

1. **准备内核 deb 包**

在一台联网的 Ubuntu 22.04 机器上下载内核包：

```bash
# 创建下载目录
mkdir -p ~/kernel-packages
cd ~/kernel-packages

# 指定内核版本
KERNEL_VERSION="5.15.0-105"

# 下载内核镜像、头文件和模块
apt download linux-image-${KERNEL_VERSION}-generic
apt download linux-headers-${KERNEL_VERSION}-generic  
apt download linux-modules-${KERNEL_VERSION}-generic

# 下载依赖包（如果有）
apt download linux-modules-extra-${KERNEL_VERSION}-generic 2>/dev/null || true

# 查看下载的文件
ls -la
```

2. **放入项目目录**

```bash
# 复制下载的 deb 包到项目
cp ~/kernel-packages/*.deb ubuntu-autoinstall/extras/debs/
```

3. **构建 ISO**

```bash
cd ubuntu-autoinstall
sudo bash build.sh
```

> **注意**：`customize-squashfs.sh` 第 5 步会自动安装 `extras/debs/` 中的所有 deb 包

---

## 方式三：使用本地 APT 仓库（高级）

### 适用场景
- 需要完全控制软件包来源
- 企业内部署
- 多版本内核管理

### 操作步骤

1. **创建本地 APT 仓库**

```bash
# 将内核 deb 包放入 repo/pool/
mkdir -p ubuntu-autoinstall/extras/repo/pool/main
cp ~/kernel-packages/*.deb ubuntu-autoinstall/extras/repo/pool/main/

# 构建仓库索引
bash ubuntu-autoinstall/build-repo.sh
```

2. **修改 `customize-squashfs.sh`**

添加本地仓库配置（参考 README 中的"本地离线 APT 仓库"章节）

---

## 验证内核版本

### 构建时验证

在 `customize-squashfs.sh` 末尾添加验证：

```bash
# 验证内核版本
step "验证内核版本"
chroot "${SQUASHFS_ROOT}" bash -c "
  echo '[INFO] 已安装的内核：'
  ls -la /boot/vmlinuz-*
  
  echo '[INFO] 内核版本详情：'
  dpkg -l | grep linux-image
"
```

### 安装后验证

```bash
ssh ubuntu@<IP>

# 查看当前运行的内核
uname -r

# 查看已安装的所有内核
dpkg -l | grep linux-image
```

---

## 快速参考

### 常用内核版本（Ubuntu 22.04）

| 内核版本 | 说明 |
|---------|------|
| 5.15.0-25-generic | 22.04 LTS 初始版本 |
| 5.15.0-105-generic | 常用稳定版本 |
| 6.2.0-26-generic | HWE 内核（硬件支持）|

### 关键文件

```
ubuntu-autoinstall/
├── customize-squashfs.sh    # 修改此文件安装内核
├── extras/debs/             # 离线 deb 包放这里
└── build.sh                 # 主构建脚本
```

---

## 总结

| 方式 | 难度 | 适用场景 | 联网要求 |
|-----|------|---------|---------|
| 方式一：在线安装 | ⭐⭐ 简单 | 构建机可联网 | 需要 |
| 方式二：deb 包替换 | ⭐⭐⭐ 中等 | 完全离线 | 不需要 |
| 方式三：本地仓库 | ⭐⭐⭐⭐ 复杂 | 企业部署 | 不需要 |

**推荐**：优先使用方式二（deb 包替换），简单可靠且完全离线。

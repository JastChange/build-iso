# 固定内核版本与离线安装

这份文档对应当前仓库的真实实现，而不是旧的“手工 patch `customize-squashfs.sh`”方案。

## 当前实现链路

当前项目已经接通了下面这条安装链：

1. `build.sh` 将 `ubuntu-autoinstall/extras/` 整体打进 ISO
2. `user-data` 的 `late-commands` 在安装阶段把 `/cdrom/extras` 复制到目标机 `/opt/extras`
3. `late-commands` 调用 `/opt/extras/scripts/post-install.sh`
4. `post-install.sh` 会：
   - 安装 Mellanox / NVIDIA 驱动（如果提供）
   - 读取 `/opt/extras/config/kernel.env`
   - 根据 `INSTALL_MODE=deb|repo|auto` 选择固定内核安装方式
   - 按配置安装固定内核版本
   - 按需执行 `apt-mark hold`

也就是说：

- 想固定某个内核版本，不需要再 patch `customize-squashfs.sh`
- 推荐通过 `kernel.env + deb/repo + post-install` 这条链来做

## 需要准备什么

### 1. 配置文件

编辑 `ubuntu-autoinstall/extras/config/kernel.env`：

```bash
KERNEL_VERSION="5.15.0-164"
KERNEL_FLAVOR="generic"
INSTALL_MODE="repo"
KERNEL_HOLD="true"
```

说明：

- `KERNEL_VERSION`
  - 支持 `5.15.0-164`
  - 也支持 `5.15.0-164-generic`
- `KERNEL_FLAVOR`
  - 通常保持 `generic`
- `INSTALL_MODE`
  - `repo`：从 `extras/repo/` 本地离线仓库安装
  - `deb`：从 `extras/debs/` 直接安装匹配的内核 deb 包
  - `auto`：repo 优先，repo 不可用时回退到 deb，再不行才回退到系统 APT 源
- `KERNEL_HOLD`
  - `true`：安装后 `apt-mark hold`
  - `false`：不锁定

默认仓库状态下，`kernel.env` 应保持：

```bash
KERNEL_VERSION=""
INSTALL_MODE="auto"
```

也就是说：

- 默认不做固定内核安装
- 只有在你明确准备好目标版本内核包之后，才填写 `KERNEL_VERSION`
- 否则 `post-install.sh` 会直接跳过内核版本锁定逻辑

### 2. 目标内核 deb 包

离线安装至少建议准备这一组：

- `linux-image-<version>`
- `linux-headers-<base-version>`（不带 flavor 的 common headers 包）
- `linux-headers-<version>`
- `linux-modules-<version>`
- `linux-modules-extra-<version>`（如果该版本存在）

例如：

- `linux-image-5.15.0-164-generic`
- `linux-headers-5.15.0-164`
- `linux-headers-5.15.0-164-generic`
- `linux-modules-5.15.0-164-generic`
- `linux-modules-extra-5.15.0-164-generic`

## 离线方式推荐

### 方式 A：`INSTALL_MODE=repo`，先下载 deb，再生成本地仓库

在一台联网 Ubuntu 机器上执行：

```bash
cd /path/to/build-iso
./scripts/download-kernel.sh 5.15.0-164 ./kernel-debs
```

把下载的包放入本地仓库目录：

```bash
mkdir -p ubuntu-autoinstall/extras/repo/pool
cp ./kernel-debs/*.deb ubuntu-autoinstall/extras/repo/pool/
```

生成仓库索引与签名：

```bash
bash ubuntu-autoinstall/build-repo.sh
```

构建 ISO：

```bash
sudo bash ubuntu-autoinstall/build.sh
```

### 方式 B：`INSTALL_MODE=deb`，直接使用 deb 包

配置：

```bash
KERNEL_VERSION="5.15.0-164"
INSTALL_MODE="deb"
KERNEL_HOLD="true"
```

把对应内核包直接放到：

```bash
ubuntu-autoinstall/extras/debs/
```

然后直接构建 ISO：

```bash
sudo bash ubuntu-autoinstall/build.sh
```

安装阶段 `post-install.sh` 会按：

1. `dpkg -i /opt/extras/debs/linux-*.deb`
2. 如有本地 repo，则优先用本地 repo 做 `apt -f install`
3. 如果没有本地 repo，则**不会再悄悄掉回系统源**，而是直接报错提示缺少依赖

注意：

- `deb` 模式不应再被理解成“天然完整离线闭环”
- 它只适合你已经把目标内核及其依赖包准备完整的场景
- 如果你不能明确准备齐全依赖（尤其是 common headers 等），优先用 `repo` 模式

### 方式 C：完全手工准备 deb，再生成本地仓库

如果你已经有现成的内核包，也可以直接手工放到：

```bash
ubuntu-autoinstall/extras/repo/pool/
```

如果最终要走 `repo` 模式，仍然执行：

```bash
bash ubuntu-autoinstall/build-repo.sh
sudo bash ubuntu-autoinstall/build.sh
```

## 安装阶段会发生什么

安装器运行到 `late-commands` 时会自动：

1. 复制 `/cdrom/extras` 到 `/target/opt/extras`
2. 复制 SSH 公钥到目标机 `ubuntu` 用户
3. 在目标机执行：

```bash
bash /opt/extras/scripts/post-install.sh
```

`post-install.sh` 会：

1. 加载 `/opt/extras/config/kernel.env`
2. 如果本地 repo 可用，则创建：

```bash
/etc/apt/sources.list.d/local-offline.list
```

3. 按 `KERNEL_VERSION` 和 `INSTALL_MODE` 安装目标内核
4. 如果 `KERNEL_HOLD=true`，执行：

```bash
apt-mark hold linux-image-... linux-headers-... linux-modules-...
```

5. 执行：

```bash
update-grub
```

## 验证方法

安装完成后进入目标机：

```bash
uname -r
dpkg -l | grep '^ii  linux-'
apt-mark showhold | grep '^linux-'
cat /var/log/post-install.log
```

重点看：

- 当前运行内核是否是指定版本
- 对应 image / headers / modules 是否已经安装
- 是否已被 hold
- `post-install.log` 里是否显示从本地 repo 或系统源安装成功

## 推荐使用方式

### 最稳的离线方式

- 准备内核 deb
- 放入 `extras/repo/pool/`
- 运行 `build-repo.sh`
- 设置 `kernel.env`
- 再构建 ISO

### 什么时候不用本地 repo

如果构建环境和安装环境都能联网，可以只设置：

```bash
INSTALL_MODE="auto"
KERNEL_VERSION="5.15.0-164"
```

这样 `post-install.sh` 会按 `repo -> deb -> 系统源` 的顺序自动回退。

## 已废弃的旧做法

下面这类做法不再推荐作为主路径：

- 手工 patch `customize-squashfs.sh`
- 直接把内核 deb 扔进 `extras/debs/` 让 squashfs 构建阶段 `dpkg -i`

原因：

- 内核更适合在目标系统内完成安装、生成 initramfs、更新 grub
- 离线 repo + `late-commands` / `post-install.sh` 更可控，也更接近真实安装链路

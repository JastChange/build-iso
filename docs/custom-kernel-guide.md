# 指定内核版本指南

固定内核版本的当前实现已经迁移到：

- `ubuntu-autoinstall/docs/offline-kernel-versioning.md`

当前不再推荐修改或 patch `customize-squashfs.sh`。请通过 `ubuntu-autoinstall/extras/config/kernel.env` 配置目标内核版本，并按主文档准备本地 repo 或 deb 包。

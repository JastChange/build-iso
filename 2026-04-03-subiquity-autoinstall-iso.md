# Ubuntu Subiquity 自动安装 ISO 设计笔记

这是早期方案文档的保留入口。当前实现已经重构为：

- 安装阶段：`post-install.sh` 只负责固定内核和注册首次开机服务。
- 首次开机阶段：`firstboot.sh` 在真实运行内核下安装 Mellanox / NVIDIA 驱动。
- 清理阶段：首次开机完成后删除 `/opt/extras`、移除 firstboot 服务，并按配置重启。

请以当前文档为准：

- 使用文档：`docs/usage.md`
- 设计文档：`docs/design.md`
- 代码审查与完成度：`docs/review.md`
- 固定内核版本：`ubuntu-autoinstall/docs/offline-kernel-versioning.md`

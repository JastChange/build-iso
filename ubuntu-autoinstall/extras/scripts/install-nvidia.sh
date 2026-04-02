#!/bin/bash
# install-nvidia.sh <nvidia.run>
set -euo pipefail
NVIDIA_RUN="$1"
LOG="/var/log/nvidia-install.log"

echo "▸ NVIDIA 驱动：$(basename "${NVIDIA_RUN}")"
chmod +x "${NVIDIA_RUN}"

# 禁用 Nouveau
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
EOF
update-initramfs -u 2>/dev/null || true

# 仅安装 userspace（内核模块由 firstboot 服务编译）
"${NVIDIA_RUN}" \
  --no-kernel-module \
  --ui=none \
  --no-questions \
  --accept-license \
  --install-libglvnd \
  2>&1 | tee "${LOG}" \
|| echo "[WARN] userspace 安装有警告，见 ${LOG}"

# 保留 .run 文件供 firstboot 服务使用
cp "${NVIDIA_RUN}" /opt/nvidia-installer.run
chmod +x /opt/nvidia-installer.run

# 注册首次启动编译服务
cat > /etc/systemd/system/nvidia-driver-firstboot.service << 'SVCEOF'
[Unit]
Description=NVIDIA Kernel Module First-Boot Compilation
After=local-fs.target
ConditionPathExists=!/var/lib/.nvidia-compiled

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=1800
ExecStart=/bin/bash -c '\
  /opt/nvidia-installer.run \
    --silent --kernel-module-only --no-nouveau-check \
    2>&1 | tee /var/log/nvidia-firstboot.log \
  && depmod -a \
  && touch /var/lib/.nvidia-compiled \
  || echo "编译失败，见 /var/log/nvidia-firstboot.log"'

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl enable nvidia-driver-firstboot.service
echo "✓ NVIDIA userspace 已安装，内核模块将在首次重启后自动编译"

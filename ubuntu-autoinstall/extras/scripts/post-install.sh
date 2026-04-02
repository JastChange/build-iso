#!/bin/bash
# post-install.sh
# 由 autoinstall late-commands 通过 curtin in-target 调用
# 运行环境：目标系统内（已 chroot 至 /target）
set -euo pipefail

EXTRAS_DIR="/opt/extras"
LOG_FILE="/var/log/post-install.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE}"; }

log "===== post-install.sh 开始 ====="

# ── Mellanox OFED ──
MLNX_TGZ=$(ls "${EXTRAS_DIR}/drivers"/MLNX_OFED_LINUX-*.tgz 2>/dev/null | head -1 || true)
if [[ -n "${MLNX_TGZ}" ]]; then
  log "发现 Mellanox OFED：$(basename "${MLNX_TGZ}")"
  bash "${EXTRAS_DIR}/scripts/install-mlnx.sh" "${MLNX_TGZ}" 2>&1 | tee -a "${LOG_FILE}"
else
  log "未发现 Mellanox OFED，跳过"
fi

# ── NVIDIA 驱动 ──
NVIDIA_RUN=$(ls "${EXTRAS_DIR}/drivers"/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1 || true)
if [[ -n "${NVIDIA_RUN}" ]]; then
  log "发现 NVIDIA 驱动：$(basename "${NVIDIA_RUN}")"
  bash "${EXTRAS_DIR}/scripts/install-nvidia.sh" "${NVIDIA_RUN}" 2>&1 | tee -a "${LOG_FILE}"
else
  log "未发现 NVIDIA 驱动，跳过"
fi

# ── 在此追加其他自定义操作 ──
# log "示例：安装 Docker..."
# curl -fsSL https://get.docker.com | sh

log "===== post-install.sh 完成 ====="

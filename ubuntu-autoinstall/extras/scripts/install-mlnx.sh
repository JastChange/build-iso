#!/bin/bash
# install-mlnx.sh <mlnx_ofed.tgz>
set -euo pipefail
MLNX_TGZ="$1"
LOG="/var/log/mlnx-ofed-install.log"

echo "▸ Mellanox OFED：$(basename "${MLNX_TGZ}")"
echo "▸ 内核：$(uname -r)"

DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  python3 python3-distutils ethtool lsof \
  tk tcl libglib2.0-0 pciutils numactl libnuma1 \
  dkms build-essential "linux-headers-$(uname -r)" 2>&1 | tee -a "${LOG}"

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT
tar xzf "${MLNX_TGZ}" -C "${TMPDIR}"

OFED_DIR=$(find "${TMPDIR}" -maxdepth 1 -type d -name "MLNX_OFED*" | head -1)
[[ -z "${OFED_DIR}" ]] && { echo "[ERROR] 未找到 MLNX_OFED 目录"; exit 1; }

mkdir -p /tmp/ofed-build
"${OFED_DIR}/mlnxofedinstall" \
  --without-fw-update \
  --add-kernel-support \
  --force \
  --tmpdir /tmp/ofed-build \
  2>&1 | tee -a "${LOG}"

echo "✓ Mellanox OFED 安装完成"

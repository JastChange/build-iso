#!/usr/bin/env bash
# 兼容旧入口：不再修改 customize-squashfs.sh，只更新 kernel.env。
set -euo pipefail

KERNEL_VERSION="${1:-}"
INSTALL_MODE="${2:-repo}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_ENV="${SCRIPT_DIR}/../ubuntu-autoinstall/extras/config/kernel.env"

if [[ -z "${KERNEL_VERSION}" ]]; then
  cat <<EOF
用法: $0 <内核版本号> [repo|deb|auto]

示例:
  $0 5.15.0-164 repo

说明:
  旧版本会向 customize-squashfs.sh 注入代码；现在固定内核由
  ubuntu-autoinstall/extras/config/kernel.env + post-install.sh 完成。
EOF
  exit 1
fi

case "${INSTALL_MODE}" in
  repo|deb|auto) ;;
  *) echo "错误：INSTALL_MODE 仅支持 repo|deb|auto" >&2; exit 1 ;;
esac

[[ -f "${KERNEL_ENV}" ]] || {
  echo "错误：找不到 ${KERNEL_ENV}" >&2
  exit 1
}

tmp_file="$(mktemp)"
awk -v version="${KERNEL_VERSION}" -v mode="${INSTALL_MODE}" '
  /^KERNEL_VERSION=/ { print "KERNEL_VERSION=\"" version "\""; next }
  /^INSTALL_MODE=/ { print "INSTALL_MODE=\"" mode "\""; next }
  { print }
' "${KERNEL_ENV}" > "${tmp_file}"
mv "${tmp_file}" "${KERNEL_ENV}"

echo "已更新 ${KERNEL_ENV}"
echo "KERNEL_VERSION=${KERNEL_VERSION}"
echo "INSTALL_MODE=${INSTALL_MODE}"
echo ""
echo "请准备对应内核 deb："
echo "  ./scripts/download-kernel.sh ${KERNEL_VERSION} ./kernel-debs"
echo "  cp ./kernel-debs/*.deb ubuntu-autoinstall/extras/repo/pool/"
echo "  bash ubuntu-autoinstall/build-repo.sh"

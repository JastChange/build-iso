#!/usr/bin/env bash
# 下载指定 ABI 的 Ubuntu 内核 deb 包，用于 extras/debs 或 extras/repo/pool。
set -euo pipefail

KERNEL_VERSION="${1:-}"
OUTPUT_DIR="${2:-./kernel-debs}"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-generic}"

usage() {
  cat <<EOF
用法: $0 <内核版本号> [输出目录]

示例:
  $0 5.15.0-164 ./kernel-debs
  KERNEL_FLAVOR=generic $0 5.15.0-164-generic ./kernel-debs
EOF
}

normalize_kernel_abi() {
  local version="$1"
  local flavor="$2"

  if [[ "${version}" == *"-${flavor}" ]]; then
    printf '%s\n' "${version}"
  else
    printf '%s-%s\n' "${version}" "${flavor}"
  fi
}

download_required() {
  local package_name="$1"
  echo "下载必需包：${package_name}"
  if ! apt download "${package_name}"; then
    echo "错误：${package_name} 下载失败" >&2
    return 1
  fi
}

download_optional() {
  local package_name="$1"
  echo "下载可选包：${package_name}"
  if ! apt download "${package_name}"; then
    echo "提示：${package_name} 不存在或当前源不可用，已跳过"
  fi
}

if [[ -z "${KERNEL_VERSION}" ]]; then
  usage
  exit 1
fi

command -v apt >/dev/null 2>&1 || {
  echo "错误：需要 apt 命令，请在 Ubuntu/Debian 系统上运行" >&2
  exit 1
}

KERNEL_ABI="$(normalize_kernel_abi "${KERNEL_VERSION}" "${KERNEL_FLAVOR}")"
KERNEL_BASE="${KERNEL_ABI%-${KERNEL_FLAVOR}}"

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

echo "========================================"
echo "内核 ABI: ${KERNEL_ABI}"
echo "输出目录: ${OUTPUT_DIR}"
echo "========================================"

cd "${OUTPUT_DIR}"

download_required "linux-headers-${KERNEL_BASE}"
download_required "linux-headers-${KERNEL_ABI}"
download_required "linux-modules-${KERNEL_ABI}"
download_required "linux-image-${KERNEL_ABI}"
download_optional "linux-modules-extra-${KERNEL_ABI}"

echo ""
echo "下载完成，文件列表："
ls -lh "${OUTPUT_DIR}"
echo ""
echo "后续步骤："
echo "  deb 模式：cp ${OUTPUT_DIR}/*.deb ubuntu-autoinstall/extras/debs/"
echo "  repo 模式：cp ${OUTPUT_DIR}/*.deb ubuntu-autoinstall/extras/repo/pool/ && bash ubuntu-autoinstall/build-repo.sh"

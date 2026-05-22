#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${ROOT_DIR}/ubuntu-autoinstall/extras/lib/iso-functions.sh"

failures=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "${message}" "${expected}" "${actual}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${message}"
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Fq -- "${pattern}" "${file}"; then
    printf 'FAIL: %s\n  missing pattern: %s\n  file: %s\n' "${message}" "${pattern}" "${file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${message}"
  fi
}

assert_symlink() {
  local path="$1"
  local message="$2"
  if [[ ! -L "${path}" ]]; then
    printf 'FAIL: %s\n  expected symlink: %s\n' "${message}" "${path}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${message}"
  fi
}

test_kernel_abi_normalization() {
  assert_eq "5.15.0-164-generic" "$(normalize_kernel_abi "5.15.0-164" "generic")" \
    "kernel ABI adds flavor when absent"
  assert_eq "5.15.0-164-generic" "$(normalize_kernel_abi "5.15.0-164-generic" "generic")" \
    "kernel ABI keeps flavor when present"
}

test_kernel_package_lists() {
  local required optional
  required="$(kernel_required_packages "5.15.0-164-generic" "generic" | paste -sd ' ' -)"
  optional="$(kernel_optional_packages "5.15.0-164-generic" "generic" | paste -sd ' ' -)"

  assert_eq "linux-headers-5.15.0-164 linux-headers-5.15.0-164-generic linux-modules-5.15.0-164-generic linux-image-5.15.0-164-generic" \
    "${required}" \
    "required kernel packages include common headers, flavored headers, modules, and image"
  assert_eq "linux-modules-extra-5.15.0-164-generic" "${optional}" \
    "optional kernel packages include modules-extra"
}

test_firstboot_service_registration() {
  local tmp service wants_link
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  register_firstboot_service "${tmp}" "/opt/extras" "true"

  service="${tmp}/etc/systemd/system/iso-firstboot.service"
  wants_link="${tmp}/etc/systemd/system/multi-user.target.wants/iso-firstboot.service"

  assert_file_contains "${service}" "ExecStart=/opt/extras/scripts/firstboot.sh" \
    "firstboot service runs the extras firstboot script"
  assert_file_contains "${service}" "ConditionPathExists=!/var/lib/ubuntu-autoinstall/firstboot.done" \
    "firstboot service is one-shot guarded"
  assert_file_contains "${service}" "Environment=FIRSTBOOT_REBOOT=true" \
    "firstboot reboot policy is persisted in the service"
  assert_symlink "${wants_link}" "firstboot service is enabled for multi-user.target"
}

test_mlnx_installer_args() {
  assert_file_contains "${ROOT_DIR}/ubuntu-autoinstall/extras/scripts/install-mlnx.sh" "--enable-opensm" \
    "mellanox installer enables OpenSM"
}

test_nvidia_installer_args() {
  assert_file_contains "${ROOT_DIR}/ubuntu-autoinstall/extras/scripts/install-nvidia.sh" "--dkms" \
    "nvidia installer uses DKMS"
  assert_file_contains "${ROOT_DIR}/ubuntu-autoinstall/extras/scripts/install-nvidia.sh" "  -s \\" \
    "nvidia installer runs silently"
}

test_kernel_abi_normalization
test_kernel_package_lists
test_firstboot_service_registration
test_mlnx_installer_args
test_nvidia_installer_args

if [[ "${failures}" -gt 0 ]]; then
  exit 1
fi

printf 'All tests passed.\n'

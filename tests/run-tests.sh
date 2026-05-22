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

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -Fq -- "${pattern}" "${file}"; then
    printf 'FAIL: %s\n  unexpected pattern: %s\n  file: %s\n' "${message}" "${pattern}" "${file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${message}"
  fi
}

assert_file_exists() {
  local file="$1"
  local message="$2"
  if [[ ! -f "${file}" ]]; then
    printf 'FAIL: %s\n  missing file: %s\n' "${message}" "${file}" >&2
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

test_post_install_sets_grub_target_kernel() {
  local script="${ROOT_DIR}/ubuntu-autoinstall/extras/scripts/post-install.sh"
  assert_file_contains "${script}" "set_grub_default_kernel" \
    "post-install has explicit GRUB target kernel selection"
  assert_file_contains "${script}" "GRUB_DEFAULT=" \
    "post-install writes GRUB_DEFAULT for the target kernel"
  assert_file_contains "${script}" "install_target_kernel" \
    "post-install installs the configured target kernel before first boot"
}

test_firstboot_gates_drivers_on_target_kernel() {
  local script="${ROOT_DIR}/ubuntu-autoinstall/extras/scripts/firstboot.sh"
  assert_file_contains "${script}" "validate_target_kernel_for_drivers" \
    "firstboot validates the running kernel before installing drivers"
  assert_file_contains "${script}" "kernel-mismatch.log" \
    "firstboot records kernel mismatch details"
  assert_file_not_contains "${script}" "先安装并切换内核" \
    "firstboot does not install and reboot into the target kernel"
}

test_final_verification_controls_cleanup_and_reboot() {
  local firstboot="${ROOT_DIR}/ubuntu-autoinstall/extras/scripts/firstboot.sh"
  local verify="${ROOT_DIR}/ubuntu-autoinstall/extras/scripts/verify-install.sh"
  assert_file_exists "${verify}" \
    "final verification script is shipped in extras"
  assert_file_contains "${firstboot}" "run_final_verification" \
    "firstboot runs final verification before cleanup"
  assert_file_contains "${firstboot}" "最终验收失败" \
    "firstboot keeps residue when final verification fails"
  assert_file_contains "${verify}" "nvidia-smi" \
    "final verification checks NVIDIA runtime"
  assert_file_contains "${verify}" "ofed_info -s" \
    "final verification checks Mellanox OFED runtime"
  assert_file_contains "${verify}" "ipmitool" \
    "final verification checks ipmitool installation"
}

test_kernel_abi_normalization
test_kernel_package_lists
test_firstboot_service_registration
test_mlnx_installer_args
test_nvidia_installer_args
test_post_install_sets_grub_target_kernel
test_firstboot_gates_drivers_on_target_kernel
test_final_verification_controls_cleanup_and_reboot

if [[ "${failures}" -gt 0 ]]; then
  exit 1
fi

printf 'All tests passed.\n'

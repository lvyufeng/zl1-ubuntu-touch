#!/usr/bin/env bash
set -euo pipefail

# Check Halium-relevant kernel config options. Read-only, no edits.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/external-halium-build-tree" >&2
  exit 2
fi

BUILD_DIR=$(realpath -m "$1")
DEFCONFIG="$BUILD_DIR/kernel/leeco/msm8996/arch/arm64/configs/lineage_zl1_defconfig"

if [[ ! -f "$DEFCONFIG" ]]; then
  echo "Missing defconfig: $DEFCONFIG" >&2
  exit 1
fi

pass=0
warn=0
fail=0

check_y() {
  local opt=$1
  local required=${2:-required}
  if grep -q "^${opt}=y$" "$DEFCONFIG"; then
    printf 'PASS %-36s y\n' "$opt"
    pass=$((pass+1))
  elif grep -q "^# ${opt} is not set$" "$DEFCONFIG"; then
    if [[ "$required" == "warn" ]]; then
      printf 'WARN %-36s not set\n' "$opt"
      warn=$((warn+1))
    else
      printf 'FAIL %-36s not set\n' "$opt"
      fail=$((fail+1))
    fi
  elif grep -q "^${opt}=" "$DEFCONFIG"; then
    printf 'WARN %-36s %s\n' "$opt" "$(grep "^${opt}=" "$DEFCONFIG" | head -1)"
    warn=$((warn+1))
  else
    if [[ "$required" == "warn" ]]; then
      printf 'WARN %-36s missing\n' "$opt"
      warn=$((warn+1))
    else
      printf 'FAIL %-36s missing\n' "$opt"
      fail=$((fail+1))
    fi
  fi
}

printf 'Checking %s\n\n' "$DEFCONFIG"

# Core container/systemd/initramfs features.
check_y CONFIG_DEVTMPFS
check_y CONFIG_DEVTMPFS_MOUNT
check_y CONFIG_CGROUPS
check_y CONFIG_CGROUP_FREEZER
check_y CONFIG_CGROUP_DEVICE warn
check_y CONFIG_CPUSETS warn
check_y CONFIG_CGROUP_CPUACCT warn
check_y CONFIG_NAMESPACES
check_y CONFIG_UTS_NS
check_y CONFIG_PID_NS
check_y CONFIG_NET_NS
check_y CONFIG_USER_NS warn
check_y CONFIG_SECCOMP warn
check_y CONFIG_SECCOMP_FILTER warn
check_y CONFIG_BLK_DEV_INITRD
check_y CONFIG_BLK_DEV_LOOP
check_y CONFIG_TMPFS
check_y CONFIG_EXT4_FS
check_y CONFIG_FUSE_FS warn
check_y CONFIG_VT warn
check_y CONFIG_UNIX98_PTYS warn
check_y CONFIG_DEVPTS_MULTIPLE_INSTANCES warn

# Android/Halium features.
check_y CONFIG_ANDROID
check_y CONFIG_ANDROID_BINDER_IPC
check_y CONFIG_ASHMEM

# Networking/container options often useful but not always fatal.
check_y CONFIG_TUN warn
check_y CONFIG_VETH warn
check_y CONFIG_BRIDGE warn
check_y CONFIG_MEMCG warn
check_y CONFIG_POSIX_MQUEUE warn

# AppArmor is expected if cmdline requests security=apparmor.
check_y CONFIG_SECURITY warn
check_y CONFIG_SECURITY_APPARMOR warn

printf '\nSummary: pass=%d warn=%d fail=%d\n' "$pass" "$warn" "$fail"
if (( fail > 0 )); then
  exit 1
fi

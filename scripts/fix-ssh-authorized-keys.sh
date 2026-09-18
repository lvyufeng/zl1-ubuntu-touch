#!/usr/bin/env bash
# Make SSH public-key login work on the zl1 Ubuntu Touch port. Run with the device in
# TWRP.
#
# The problem, and why the June attempts could not have worked:
#
#   sshd_config never sets AuthorizedKeysFile, so sshd falls back to its default,
#   `.ssh/authorized_keys` relative to the user's home. For root that is /root/.ssh.
#   /root IS a writable-path, but it is NOT the path the June scripts wrote to:
#   the writable-paths "auto" destination for a mount point resolves under
#   /userdata/system-data/, so /root comes from /userdata/system-data/root — while
#   install-ssh-to-userdata.sh wrote to /userdata/root/. The key landed in a directory
#   nothing reads. (The device still has that stray copy at /data/root/.ssh.)
#
#   Separately, PasswordAuthentication=no is set by
#   /etc/ssh/sshd_config.d/50-lxc-android-config.conf, so publickey is the only method.
#
# The fix is to stop depending on which home directory root ends up with. /etc/ssh is a
# persistent writable-path bind-mounted from /userdata/system-data/etc/ssh — it holds the
# host keys and the config, and it is already proven to survive reboots. So point
# AuthorizedKeysFile at a file under it:
#
#   AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
#
# The key is written in both places (the new /etc/ssh path and the correct
# system-data/root path), so whichever mechanism sshd uses, it finds one.
#
# Nothing here touches a partition or the rootfs; userdata is edited as plain files from
# TWRP. Idempotent.
#
# Usage: fix-ssh-authorized-keys.sh [--yes]

set -euo pipefail

SER="33e80afe"
KEYFILE="${HOME}/.ssh/id_ed25519.pub"
SYSTEM_DATA="/data/system-data"
SSH_DIR="/data/system-data/etc/ssh"
CONF="$SSH_DIR/sshd_config"
AKD="$SSH_DIR/authorized_keys.d"
# The persistent systemd tree. It must be the one under /data/system-data — from TWRP a
# bare /etc/systemd/system is *recovery's own*, and writing there would be wrong and
# potentially harmful. The rootfs's writable-paths entry for /etc/systemd/system is
# "auto persistent", which resolves to this path.
SYSD="$SYSTEM_DATA/etc/systemd/system"
ROOT_SSH="/data/system-data/root/.ssh"

[[ "${1:-}" == "--yes" ]] || { echo "refusing without --yes" >&2; exit 2; }

adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || { echo "target $SER not visible in adb (need TWRP)" >&2; exit 1; }
[[ -f "$KEYFILE" ]] || { echo "missing public key: $KEYFILE" >&2; exit 1; }

sh_() { adb -s "$SER" shell "$@"; }

echo "== what is there now =="
sh_ "ls -la '$SSH_DIR' 2>&1; echo '--- authorized_keys.d ---'; ls -la '$AKD' 2>&1; echo '--- root home ---'; ls -la '$ROOT_SSH' 2>&1" | tr -d '\r'

echo
echo "== 1/4 set AuthorizedKeysFile =="
sh_ "grep -qE '^[[:space:]]*AuthorizedKeysFile' '$CONF' && \
     sed -i 's|^[[:space:]]*AuthorizedKeysFile.*|AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u|' '$CONF' || \
     printf '\n# Added for the zl1 port: /etc/ssh is a persistent writable-path, a user'\''s\n# home directory may not be.\nAuthorizedKeysFile /etc/ssh/authorized_keys.d/%%u\n' >> '$CONF'"
sh_ "grep -n 'AuthorizedKeysFile' '$CONF'" | tr -d '\r'

echo
echo "== 2/4 install the key under /etc/ssh =="
printf '%s\n' "$(cat "$KEYFILE")" > /tmp/zl1-ssh-key.pub
sh_ "mkdir -p '$AKD' && chmod 0755 '$AKD'"
adb -s "$SER" push /tmp/zl1-ssh-key.pub "$AKD/root" >/dev/null
sh_ "chmod 0644 '$AKD/root'; chown 0:0 '$AKD/root' 2>/dev/null || true; ls -l '$AKD/root'; cat '$AKD/root'" | tr -d '\r'
rm -f /tmp/zl1-ssh-key.pub

echo
echo "== 3/4 install the key in the correct root home as well =="
sh_ "mkdir -p '$ROOT_SSH' && chmod 0700 '$ROOT_SSH'"
adb -s "$SER" push "$KEYFILE" "$ROOT_SSH/authorized_keys" >/dev/null
sh_ "chmod 0600 '$ROOT_SSH/authorized_keys'; chown 0:0 '$ROOT_SSH/authorized_keys' 2>/dev/null || true; ls -l '$ROOT_SSH'; cat '$ROOT_SSH/authorized_keys'" | tr -d '\r'

echo
echo "== 4/4 note the stale copy left by the June script =="
sh_ "ls -la /data/root/.ssh/ 2>&1" | tr -d '\r'
echo "   (left in place on purpose — it is harmless, and removing it would lose the"
echo "    record of what the June attempt did.)"

echo
echo "== 5/5 neutralise the service that turns sshd off =="
# Ubuntu Touch ships lxc-android-config-disable-ssh-socket.service, wanted by
# multi-user.target. Its whole job is to stop sshd listening — which is why the
# 2026-09-18 boot had nothing on port 22 while an earlier boot did, even though
# AuthorizedKeysFile and the key were already right.
#
# Refuse to touch anything if the tree does not look like the UT one: getting this path
# wrong would edit recovery's own systemd configuration.
if ! sh_ "[ -d '$SYSD' ] && echo present" | tr -d '\r' | grep -q present; then
  echo "  SKIPPED: $SYSD does not exist — refusing to guess at the path" >&2
else
  sh_ "ls -l '$SYSD/multi-user.target.wants/lxc-android-config-disable-ssh-socket.service' 2>&1" | tr -d '\r'
  sh_ "ln -sfn /dev/null '$SYSD/lxc-android-config-disable-ssh-socket.service'
       rm -f '$SYSD/multi-user.target.wants/lxc-android-config-disable-ssh-socket.service'
       ls -l '$SYSD/lxc-android-config-disable-ssh-socket.service'" | tr -d '\r'
  echo "   (masked: the unit points at /dev/null and is no longer wanted)"
fi

echo
echo "syncing (the caller reboots straight after this)..."
sh_ "sync" || true

echo
echo "done. After the next boot:  ssh -o BatchMode=yes root@10.15.19.82 'id'"

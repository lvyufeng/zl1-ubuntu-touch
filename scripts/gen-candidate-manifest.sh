#!/usr/bin/env bash
# Regenerate manifests/halium-boot-candidates.md.
#
# The candidate boot images live in /mnt/data/halium-zl1-candidates/ (outside
# this repo — *.img is gitignored). This script walks that directory and emits
# a tracked table of filename -> size -> SHA256 -> known result, so the history
# of what was tried survives even if the images are lost.
#
# Usage: gen-candidate-manifest.sh [CANDIDATE_DIR] [OUT_MD]

set -euo pipefail

CAND="${1:-/mnt/data/halium-zl1-candidates}"
OUT="${2:-/mnt/data/zl1-bb10/manifests/halium-boot-candidates.md}"

[[ -d "$CAND" ]] || { echo "no such directory: $CAND" >&2; exit 1; }

# Known outcomes, taken from docs/session-notes/ and
# docs/ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md. Anything not listed is an
# intermediate iteration whose result was never recorded as a stable conclusion.
result_of() {
  case "$1" in
    halium-boot-zl1-v63-usbd-disabled.img)
      echo "**KNOWN GOOD** — UT + Android container + RNDIS all up for ~9 min" ;;
    halium-boot-zl1-filtered-dtb-postswitch-debug-v61-postinit-monitor.img)
      echo "**KNOWN GOOD** — Android container reached zygote64/zygote/surfaceflinger" ;;
    halium-boot-zl1-v64-production-no-android.img)
      echo "partial — RNDIS up ~20 s, then lost; system booted" ;;
    halium-boot-zl1-v65-production-keeper.img|halium-boot-zl1-v65-production-with-keeper.img)
      echo "**FAILED** — no RNDIS, fell back to stock Android" ;;
    halium-boot-zl1-v66-guardian.img)
      echo "**FAILED** — no RNDIS, fell back to stock Android" ;;
    halium-boot-zl1-v67-from-v63-lxc-masked.img)
      echo "**FAILED** — no ADB, no RNDIS, unknown state" ;;
    halium-boot-zl1-v71-rootfs-nm-inject.img)
      echo "**FAILED** — never connected (211 s of DISCONNECT)" ;;
    halium-boot-zl1-filtered-dtb.img)
      echo "filtered-DTB reference build (2026-06-07). **Not reachable by rebuild** — its built-in initramfs cpio carries a stale mtime; see docs/ubuntu-touch/19-phase1-reproducible-build.md §2" ;;
    halium-boot-zl1-v63-debug-shell.img)
      echo "v63 + \`zl1_debug_shell=1\` on the cmdline only (kernel and ramdisk byte-identical to v63). **The flag does reach the ramdisk, but busybox telnetd exits rc=1, so it does not actually give a shell** — measured 2026-09-17, docs/ubuntu-touch/27-what-a-reachable-window-shows.md" ;;
    halium-boot-zl1-v63-noreassert.img)
      echo "**the next one to test** — v63 with one change: the keeper no longer rebuilds the USB gadget after killing a USB manager. Measured 2026-09-17: that rebuild re-enumerated the device every ~118 s (16 times in 36 minutes) and the link was reachable for 2 pings of those 36 minutes. Verified to differ from v63 in exactly one initramfs file" ;;
    halium-boot-zl1-v63-rebuilt.img)
      echo "v63 rebuilt from tracked source (boot/v63/ + make-v63-boot-image.sh): v63's kernel + this repo's reconstruction of its initramfs. Verified content-identical to halium-boot-zl1-v63-usbd-disabled.img in every component; the hash differs only because the initramfs gzip framing does" ;;
    halium-boot-zl1-v63-modemfw.img)
      echo "**the modem-firmware mount, built and verified offline -- never run on hardware yet** (docs/ubuntu-touch/154-no-in-kernel-client-loads-the-modem-so-the-mount-has-to-happen-itself.md). One deliberate change to the rebuilt v63: the initramfs carries a fallback fstab (\`zl1-android-fstab\`: the \`modem\` partition, read-only, at \`/vendor/firmware_mnt\`) and halium's Android-partition loop reports an unmatched glob, an absent device and a failed mount instead of staying silent. **Kernel, the five appended DTBs and the cmdline are byte-identical to the rebuilt v63** (the kernel Image differs in 29 bytes: the build-id note), so the undo is flashing the previous boot image" ;;
    halium-boot-zl1-v63-modemfstab.img)
      echo "**SUPERSEDED -- do not flash.** An earlier draft of the modem mount, replaced by \`halium-boot-zl1-v63-modemfw.img\` (docs/ubuntu-touch/154-...). It was built from a patch that no longer exists in this repo; it was never run on hardware" ;;
    halium-boot-zl1-v63-uether-txwakeup.img)
      echo "**built to test** — v63's initramfs and cmdline (content-verified against the v63 binary) on the transmit-wakeup kernel. This is the image that asks whether the u_ether patch removes the intermittent stall" ;;
    halium-boot-zl1-uether-txwakeup.img)
      echo "**mitigation candidate** — the reproducible baseline plus the u_ether.c transmit-wakeup patch (scripts/patch-uether-tx-wakeup.sh). Kernel-only: ramdisk and appended DTBs are byte-identical to the baseline. Fixes the confirmed code fact that netif_wake_queue() was reachable only from tx_complete(); not yet shown to be the cause of the stall on hardware" ;;
    halium-boot-zl1-reproducible-20260916.img)
      echo "**Phase 1 baseline** — reproduced byte-for-byte by two clean rebuilds; this is the reproducible target SHA" ;;
    halium-boot-zl1-filtered-dtb-postswitch-debug-v*.img)
      echo "debug iteration" ;;
    *.img)
      echo "—" ;;
  esac
}

{
  echo "# halium-boot candidate manifest"
  echo
  echo "Generated by \`scripts/gen-candidate-manifest.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  echo
  echo "Images live in \`$CAND\` (\`*.img\` is gitignored, so they are not in this"
  echo "repo). The SHA256 below is what identifies an image: the \`v\` numbers are"
  echo "just labels from the sessions that produced them and two different builds"
  echo "can share a label."
  echo
  echo "Results are quoted from \`docs/session-notes/\`; \`—\` means the iteration's"
  echo "outcome was never written down as a stable conclusion."
  echo
  echo "| file | bytes | sha256 | result |"
  echo "| --- | ---: | --- | --- |"
  while IFS= read -r f; do
    full="$CAND/$f"
    size="$(stat -c%s "$full")"
    sha="$(sha256sum "$full" | awk '{print $1}')"
    printf '| `%s` | %s | `%s` | %s |\n' "$f" "$size" "$sha" "$(result_of "$f")"
  done < <(cd "$CAND" && ls -1 *.img | sort)
} > "$OUT"

# Also emit SHA256SUMS alongside the images, so flash-boot-image.sh can refuse
# any image that is not hash-verified against a known build.
( cd "$CAND" && sha256sum *.img ) > "$CAND/SHA256SUMS"

echo "wrote $OUT ($(grep -c '^| `' "$OUT") images)"
echo "wrote $CAND/SHA256SUMS ($(wc -l < "$CAND/SHA256SUMS") entries)"

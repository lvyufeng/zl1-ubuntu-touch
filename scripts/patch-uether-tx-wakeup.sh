#!/usr/bin/env bash
# Apply (or remove) the zl1 transmit-wakeup patch to the Halium kernel's u_ether.c.
#
# Why: about 1 boot in 4, the device ends up able to receive but not transmit. The
# device's own counters say packets reach rndis0 while tx_packets freezes and never moves
# again for the rest of the boot. See
# docs/ubuntu-touch/22-stage2-coldboot-results.md section 5.
#
# In this u_ether.c there are exactly three places that re-open a stopped transmit queue:
#
#   eth_start()        line ~1341  called from eth_open / gether_up
#   tx_complete()      line ~876   the USB transmit-completion callback
#   process_tx_w()     line ~1059  the aggregation worker, but only netif_start_queue()
#                                  and only when it did not break out of its loop
#
# netif_wake_queue() — the one that also re-schedules the qdisc — is reachable from
# tx_complete() and eth_start() only. So a single lost completion leaves the queue stopped
# with nothing left to re-open it, and the worker that exists to drain tx_skb_q does not
# re-arm itself either. The file's own comment acknowledges the shape of the hazard:
#
#     should allow aggregation only, if the number of requests queued more than the tx
#     requests that can be queued with no interrupt flag set sequentially. Otherwise,
#     packets may be blocked forever.
#
# The patch makes process_tx_w() — already the thing that drains tx_skb_q — responsible
# for both re-arming itself while packets remain and waking the queue instead of merely
# starting it. It is deliberately small and touches nothing on the RX path.
#
# The re-arm is guarded on req_cnt > 0, i.e. on the pass having actually moved something.
# Without that guard a worker with no free request would re-queue itself in a hot loop,
# which on a single-threaded (max_active=1) workqueue would burn a CPU — and the
# surrounding code already frets about the watchdog kicking in.
#
# IMPORTANT: this is a *mitigation candidate*, not a confirmed fix. The on-device
# netwatch log is what will say whether it helps (scripts/read-netwatch-log.sh shows the
# tx_pkts_rcvd / tx_qlen / tx_throttle series). Do not treat the device-side watchdog as
# redundant until that has been read.
#
# Usage:
#   patch-uether-tx-wakeup.sh <BUILD_DIR> --apply
#   patch-uether-tx-wakeup.sh <BUILD_DIR> --remove
#   patch-uether-tx-wakeup.sh <BUILD_DIR> --status

set -euo pipefail

BUILD_DIR="$(realpath -m "${1:?usage: $0 <BUILD_DIR> --apply|--remove|--status}")"
ACTION="${2:?usage: $0 <BUILD_DIR> --apply|--remove|--status}"
SRC="$BUILD_DIR/kernel/leeco/msm8996/drivers/usb/gadget/function/u_ether.c"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

MARKER="zl1: keep the transmit path moving"

ANCHOR='	}
	spin_unlock_irqrestore(&dev->req_lock, flags);
}

static netdev_tx_t eth_start_xmit(struct sk_buff *skb,'

PATCH_BLOCK='	}
	spin_unlock_irqrestore(&dev->req_lock, flags);

	/*
	 * '"$MARKER"' — u_ether.c
	 *
	 * netif_wake_queue() is otherwise reachable only from tx_complete(), so one
	 * lost completion leaves the queue stopped for the rest of the boot, and this
	 * worker — the only thing that drains tx_skb_q — does not re-arm itself after
	 * breaking out of the loop above. Both are repaired here: re-queue the work
	 * while packets remain, and wake (not merely start) the queue.
	 */
	if (net && req_cnt > 0) {
		/*
		 * req_cnt > 0 means this pass actually moved something, so there is a
		 * free request to work with. Re-queue only then: if every request is
		 * stuck (tx_reqs empty) nothing can make progress, and re-arming
		 * would just spin this single-threaded worker.
		 */
		if (skb_queue_len(&dev->tx_skb_q) > 0)
			queue_work(uether_tx_wq, &dev->tx_work);
		if (netif_queue_stopped(net) &&
		    dev->tx_skb_q.qlen < tx_start_threshold)
			netif_wake_queue(net);
	}
}

static netdev_tx_t eth_start_xmit(struct sk_buff *skb,'

apply_patch() {
  if grep -q "$MARKER" "$SRC"; then
    echo "already applied: $SRC"
    return 0
  fi
  SRC="$SRC" ANCHOR="$ANCHOR" PATCH_BLOCK="$PATCH_BLOCK" python3 - <<'PY'
import os, sys
src = os.environ['SRC']
anchor = os.environ['ANCHOR']
block = os.environ['PATCH_BLOCK']
text = open(src, encoding='utf-8', errors='surrogateescape').read()
n = text.count(anchor)
if n != 1:
    sys.exit(f'anchor matched {n} times, expected exactly 1 — refusing to patch')
open(src, 'w', encoding='utf-8', errors='surrogateescape').write(text.replace(anchor, block, 1))
print('patched')
PY
  echo "applied to $SRC"
}

remove_patch() {
  if ! grep -q "$MARKER" "$SRC"; then
    echo "not applied: $SRC"
    return 0
  fi
  SRC="$SRC" ANCHOR="$ANCHOR" PATCH_BLOCK="$PATCH_BLOCK" python3 - <<'PY'
import os, sys
src = os.environ['SRC']
anchor = os.environ['ANCHOR']
block = os.environ['PATCH_BLOCK']
text = open(src, encoding='utf-8', errors='surrogateescape').read()
if text.count(block) != 1:
    sys.exit('patched block matched != 1 time — remove by hand')
open(src, 'w', encoding='utf-8', errors='surrogateescape').write(text.replace(block, anchor, 1))
print('removed')
PY
  echo "removed from $SRC"
}

case "$ACTION" in
  --apply)
    apply_patch
    # A stale object would otherwise be linked without the change.
    OBJ="$BUILD_DIR/out/target/product/zl1/obj/KERNEL_OBJ/drivers/usb/gadget/function/u_ether.o"
    [[ -f "$OBJ" ]] && { rm -f "$OBJ"; echo "removed stale $OBJ"; }
    ;;
  --remove)
    remove_patch
    OBJ="$BUILD_DIR/out/target/product/zl1/obj/KERNEL_OBJ/drivers/usb/gadget/function/u_ether.o"
    [[ -f "$OBJ" ]] && { rm -f "$OBJ"; echo "removed stale $OBJ"; }
    ;;
  --status)
    if grep -q "$MARKER" "$SRC"; then echo "applied"; else echo "not applied"; fi
    ;;
  *)
    echo "unknown action: $ACTION" >&2; exit 2 ;;
esac

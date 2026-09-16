# Waiting for Device to Enter Recovery Mode

## Current Status (2026-06-15 Evening)

**Background task running**: Waiting for device to appear in recovery or fastboot mode
**Duration**: 50+ seconds so far
**Action**: Manual power button press may be needed to boot into recovery

## What Will Happen When Device Appears

The script `scripts/install-ssh-to-userdata.sh` will automatically execute:

1. Mount userdata: `/dev/block/sda10` → `/tmpmnt`
2. Create directory: `/tmpmnt/root/.ssh/`
3. Install authorized_keys to **userdata** (the CORRECT location!)
4. Set permissions: 700 for directory, 600 for file
5. Unmount cleanly

## Why This Will Work

**Previous attempts failed because**: We edited `/mnt/rootfs/root/.ssh/` (in rootfs image)

**But at runtime**: `/root` is **bind-mounted from userdata**, so SSH reads from userdata, not rootfs!

**This time**: We're installing directly to userdata (`/tmpmnt/root/.ssh/`)

## After SSH Fix

Once device boots V63 with corrected SSH keys:
```bash
ssh root@10.15.19.82  # SHOULD WORK!
```

Then begin full peripheral investigation:
- Display/framebuffer test
- Touchscreen identification
- Modem activation
- WiFi setup
- Sensor access
- Audio testing

## Confidence Level

**Very High** - The bind-mount discovery fully explains all previous failures. This is the correct solution.

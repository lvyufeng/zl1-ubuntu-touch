# Prior Ubuntu Touch / Halium artifacts

Old community prior art exists for LeEco Le Pro3 / X72X / `zl1`:

- XDA thread: `[ROM][TREBLE][X72X] Halium 9.0 for LePro3`
- Author reported: haky86
- Approximate date: 2021-02
- Method: LineageOS 16 Android 9 Treble base, UBports GSI installer, patched Halium boot image

Reported prerequisites from the old thread:

- unlocked bootloader
- TWRP for `zl1`
- Android 9 Treble-enabled base ROM
- recommended LineageOS 16 build: `lineage-16.0-20190310_112900-UNOFFICIAL-zl1.zip`
- UBports GSI installer v9
- patched `halium-boot` image for LePro3

## Current artifact status

Confirmed still visible:

- TWRP page for `zl1`: `https://dl.twrp.me/zl1/`
- SourceForge LineageOS 16 files for `zl1`, including `lineage-16.0-20190310_112900-UNOFFICIAL-zl1.zip`

Problematic or missing:

- `https://build.lolinet.com/file/halium/GSI/ubports_GSI_installer_v9.zip` returned 404 during research.
- `08022021-halium-boot-haky86.img` was not visible in the checked SourceForge listing.

Therefore the boot image needs to be rebuilt from source, and the Ubuntu Touch rootfs/GSI side still needs a trusted replacement.

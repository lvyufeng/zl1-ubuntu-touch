# LeEco zl1 BlackBerry 10 Porting Notes

This repository tracks research and experiments for evaluating whether BlackBerry 10 / QNX can be ported to the LeEco Pro3 (`zl1`, `le_zl1`, Qualcomm MSM8996 / Snapdragon 821).

## Goals

- Document the target device hardware, boot chain, partition layout, and firmware constraints.
- Collect BlackBerry 10 / QNX compatibility research relevant to Qualcomm Android devices.
- Record non-destructive analysis steps before any flashing or partition writes.
- Preserve reproducible notes, scripts, and artifacts used during the investigation.

## Current status

Initial repository created. No porting artifacts or device modifications have been added yet.

## Safety notes

- Prefer read-only inspection first.
- Back up critical partitions before any write operation.
- Avoid flashing experiments while the device battery is low.

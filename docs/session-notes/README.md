# Session notes

Working notes written during the Ubuntu Touch / Halium 9 bring-up sessions
between 2026-06-07 and 2026-06-17. They are kept verbatim as the chronological
record of what was tried and what was learned; several of them are written in
the middle of a debugging run and supersede each other.

For the stable conclusions, read the documents under
[`../ubuntu-touch/`](../ubuntu-touch/) first — in particular:

- [`../ubuntu-touch/17-adaptation-plan.md`](../ubuntu-touch/17-adaptation-plan.md)
- [`../ubuntu-touch/00-safety.md`](../ubuntu-touch/00-safety.md)
- [`../ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md`](../ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md)
- [`../ubuntu-touch/SSH-FINAL-STATUS.md`](../ubuntu-touch/SSH-FINAL-STATUS.md)

> **Known bad conclusion in these notes.** Several entries read the Android container
> state from `lxc-ls`, which reports `STOPPED` even while the container is running,
> because `lxc-start` is invoked with `-F` (foreground). The Android container did in
> fact start under both v61 and v63. Use `lxc-info -n android` or process existence
> instead. See [`../ubuntu-touch/17-adaptation-plan.md`](../ubuntu-touch/17-adaptation-plan.md) §1.2.

## Root-cause write-ups (still current)

| File | Content |
| --- | --- |
| `ROOTFS-NETWORK-FIX.txt` | Why the Ubuntu Touch rootfs had no RNDIS networking, and the fix. |
| `BREAKTHROUGH-clean-userdata-real-problem.txt` | Clean userdata changes the boot outcome; the earlier failures were not a pure image problem. |
| `DEVICE-STATE-CORRUPTION-DISCOVERED.txt` | Device state itself can be corrupt between attempts. |
| `FAILURE-PATTERN-V64-V67.txt` | Analysis of the v64–v67 persistence failures. |
| `FINAL-ANALYSIS-AND-RECOMMENDATIONS.txt` | Consolidated analysis of the USB network work. |
| `STRATEGIC-ANALYSIS-NEXT-STEPS.md` | Where the port stands and what to do next. |
| `NEXT-STEPS-SSH-ENABLEMENT.md` | SSH investigation and why it was judged not viable. |

## Session records, oldest first

| File | Date |
| --- | --- |
| `DEVICE-STATE-CORRUPTION-DISCOVERED.txt` | 2026-06-14 |
| `SESSION-END-DEVICE-RECOVERY-NEEDED.txt` | 2026-06-14 |
| `V71-STATUS-DEVICE-RECOVERY-NEEDED.txt` | 2026-06-14 |
| `RECOVERY-AND-CLEAN-TEST-PLAN.txt` | 2026-06-14 |
| `SESSION-SUMMARY-2026-06-15.md` | 2026-06-15 |
| `END-OF-SESSION-2026-06-15.md` | 2026-06-15 |
| `FINAL-REPORT-2026-06-15-EVENING.md` | 2026-06-15 |
| `SESSION-COMPLETE-2026-06-15-FINAL.md` | 2026-06-15 |
| `NEXT-STEPS-PERIPHERALS-V72.md` | 2026-06-15 |
| `WAITING-FOR-DEVICE-RECOVERY.md` | 2026-06-15 |
| `DEVICE-V72-FAILED-FALLBACK-TO-V63.txt` | 2026-06-15 |
| `SESSION-SUMMARY-2026-06-16.md` | 2026-06-16 |
| `SESSION-END-2026-06-16.md` | 2026-06-16 |
| `FINAL-SESSION-SUMMARY-2026-06-16.md` | 2026-06-16 |
| `FINAL-RECOMMENDATION.md` | 2026-06-16 |
| `V73-BUILD-STATUS.md`, `V73-BUILDING-NOW.md`, `V73-READY-TO-COMPLETE.md`, `V73-TEST-NOW.md`, `HOW-TO-COMPLETE-V73.md`, `NEXT-STEPS-V73-HTTP.md` | 2026-06-16 |
| `CURRENT-STATUS-WAITING.md` | 2026-06-16 |
| `DEVICE-IN-EDL-2026-06-17.md` | 2026-06-17 — device left in EDL, needs a physical power-cycle |

## Where the work stopped

`DEVICE-IN-EDL-2026-06-17.md` is the last entry: the target device
(serial `33e80afe`) was left in Qualcomm EDL (`05c6:9008`) after the v73
`fastboot boot` attempt. Nothing software-side can move it out of EDL — it needs
a manual power-cycle. The recovery plan and the fallback to the known-good v63
image are in that file.

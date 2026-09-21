# Stage 2.4 — cold-boot trials

One row per trial. Rows are appended by `scripts/verify-over-ssh.sh` (the SSH check,
used since 2026-09-19) or were entered by hand from `scripts/stage2-coldboot-trial.sh`
(the older RNDIS-probe check). Stage 2.4 asks for three consecutive cold boots with the
same result.

Columns: `container` is the `lxc-start` PID (or `none`), `HAL` is the count of
`android.hardware` processes, `t99` is the route count in table 99, `coldboot_done` is
whether the container reached `/dev/.coldboot_done`.

| # | UTC | method | pid1 | link | t99 | container | HAL | coldboot_done | note |
| ---: | --- | --- | --- | --- | ---: | --- | ---: | --- | --- |
| 1 | 20260917T144328Z | rndis-probe | ? | ? | ? | unknown | 0 | ? | pre-SSH era: gadget up, no traffic through, status page unreachable — columns not comparable to the rows below |
| 2 | 20260919T172606Z | ssh | systemd | ok | 2 | 34662 | 24 | no | first SSH-based trial; uptime already 25 min, so not a cold boot |
| 3 | 20260919T172723Z | ssh | ? | ? | ? | none | 0 | ? | cold boot #1 after reboot — verifier ran before SSH was up |
| 4 | 20260919T173421Z | ssh | ? | ? | ? | none | 0 | ? | cold boot #1 (SSH waited) — same problem |
| 5 | 20260919T173530Z | ssh | systemd | ok | 0 | 34961 | 24 | no | cold boot #1 (old netwatch, rules-based fix) |
| 6 | 20260919T175032Z | ssh | ? | ? | ? | none | 0 | ? | cold boot #2 — device ran a netwatch build whose edit had deleted five functions |
| 11 | 20260920T012033Z | ssh | systemd | ok | 2 | 34312 | 23 | no | cold boot #2 (three-table netwatch, installed and verified in TWRP) |
| 12 | 20260920T012142Z | ssh | systemd | ok | 2 | 34312 | 24 | no | cold boot #2 (three-table netwatch) |
| 13 | 20260921T005739Z | ssh | systemd | ok | 2 | 34583 | 24 | no | cold boot #2 (stage 2.4) |

## Which rows count

Row numbers are the writing script's counter, not a sequence: the number jumped from 6 to
11 when `verify-over-ssh.sh` replaced `stage2-coldboot-trial.sh` as the writer, and rows
7–10 never existed (`git log` on this file confirms it).

| row | counts? | why |
| --- | --- | --- |
| 1 | no | pre-SSH probe; the check could not see the system, only the link |
| 2 | no | not a cold boot — the device had been up 25 minutes |
| 3, 4 | no | verifier ran before SSH was up; the device was fine, the check was early |
| 5 | **yes** | cold boot #1: systemd PID 1, container running, 24 HAL processes, link reachable 30/30, watchdog never healed (STALL 0, heals 0) |
| 6 | no | the instrument was broken, not the system — see below |
| 11, 12 | **yes** | the same boot verified twice, 69 s apart, with the same result |
| 13 | **yes** | cold boot #2 of the 2026-09-21 run |

## A note on how row 6 went wrong

The broken build came from an editing mistake: a Python replacement sliced from the fix's
comment block to `hwcheck()`, which spans `restore_addrs`, `heal_reenumerate`,
`heal_rebind_function`, `heal` and `netsnap`. Deleting function definitions is not a
syntax error, so `sh -n` passed and the file went from 23513 to 19043 bytes unnoticed.

The check that would have caught it is not a syntax check but a content check — assert
the functions the script is supposed to have are still there. That is now what
`scripts/check-netwatch-integrity.sh` does, and the installer refuses a build that fails
it. It is cheaper than the two boots it cost.

## The 2026-09-20 boot that was counted as a failure, and was not

Between rows 12 and 13 there was a boot recorded here as "cold boot #3: **failed** —
RNDIS present, no traffic through, SSH dropped during the key exchange", and the count
held at 2 of 3 because of it. Reading that boot's netwatch log on 2026-09-21 showed the
verdict was about the *host*, not the device: rndis0 reported `rx_packets=0` at every one
of its 10205 samples, i.e. nothing ever reached the device from this side, because the
last host-watcher run had ended 32 hours before that boot began.

The device-side log cannot tell "the link is broken" apart from "there was never anything
at the other end". So a boot is only a trial once the host side is up, and
`run-stage24-and-25.sh` now starts `host-watch-usb0.sh` before the first reboot and makes
each trial wait for the host to see `usb0` go away and come back before it judges
anything. See [`37-the-trial-that-had-no-peer.md`](37-the-trial-that-had-no-peer.md).

That boot is therefore **not** a failed trial and is not counted either way. The count
restarts at row 13.

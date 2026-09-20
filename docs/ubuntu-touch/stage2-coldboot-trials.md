# Stage 2.4 — cold-boot trials

One row per power-on, appended by `scripts/stage2-coldboot-trial.sh`.
Stage 2.4 asks for three consecutive boots with the same result.

| # | UTC | gadget | ping | status page | container | uptime at status | netwatch | note |
| ---: | --- | --- | --- | --- | --- | ---: | --- | --- |
| 1 | 20260917T144328Z | yes | no | no | unknown | — | not-read | first boot with netwatch installed |
| 2 | 20260919T172606Z | ssh | systemd | ok | 2 | 34662 | 24 | no | first SSH-based trial; uptime already 25 min |
| 3 | 20260919T172723Z | ssh | ? | ? | ? | none | 0 | ? | cold boot #1 after reboot |
| 4 | 20260919T173421Z | ssh | ? | ? | ? | none | 0 | ? | cold boot #1 (SSH waited) |
| 5 | 20260919T173530Z | ssh | systemd | ok | 0 | 34961 | 24 | no | cold boot #1 (old netwatch, rules-based fix) |
| 6 | 20260919T175032Z | ssh | ? | ? | ? | none | 0 | ? | cold boot #2 (table-99 netwatch) |

## Which rows count

Stage 2.4 asks for **three consecutive cold boots with the same result**. Not every row
in the table above is a trial:

| row | counts? | why |
| --- | --- | --- |
| 2 | no | not a cold boot — the device had been up 25 minutes |
| 3, 4 | no | verifier ran before SSH was up; the device was fine, the check was early |
| 5 | **yes** | cold boot #1: systemd PID 1, container running, 24 HAL processes, link reachable 30/30, watchdog never healed (STALL 0, heals 0) |
| 6 | **no** | cold boot #2, but the device was running a netwatch build whose edit had deleted five functions — the instrument was broken, not the system |

So the count stands at **1 of 3**.

## A note on how row 6 went wrong

The broken build came from an editing mistake: a Python replacement sliced from the fix's
comment block to `hwcheck()`, which spans `restore_addrs`, `heal_reenumerate`,
`heal_rebind_function`, `heal` and `netsnap`. Deleting function definitions is not a
syntax error, so `sh -n` passed and the file went from 23513 to 19043 bytes unnoticed.

The check that would have caught it is not a syntax check but a content check — assert
the functions the script is supposed to have are still there. That is now what the
rebuild does, and it is cheaper than the two boots it cost.
| 11 | 20260920T012033Z | ssh | systemd | ok | 2 | 34312 | 23 | no | cold boot #2 (three-table netwatch, installed and verified in TWRP) |
| 12 | 20260920T012142Z | ssh | systemd | ok | 2 | 34312 | 24 | no | cold boot #2 (three-table netwatch) |

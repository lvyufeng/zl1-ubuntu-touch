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

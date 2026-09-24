#!/usr/bin/env bash
# zl1-hardware-inventory -- enumerate the zl1's hardware from its own device trees, and
# say which block nothing in this tree reads.
#
# Why this exists: the goal for this port is "所有的硬件都能驱动" -- every piece of hardware driven.
# The tree has ~25 probes, one per subsystem, and they were all written when a particular symptom
# was being chased (screen dark, GPS silent, fingerprint EINVAL). Nobody has ever listed the
# *hardware* and asked which blocks have no probe at all, so the answer has been whatever the last
# symptom was about. This script derives that list from the device's own DTBs, so it cannot drift
# into being a memory of the last conversation.
#
# The DTB is the right source because it is the vendor's own enumeration: every block the kernel
# can bind is a node with a `compatible`, and a block with no node cannot exist on the board at all.
# It is also the only source that works with **no device attached** -- which matters, because the
# device is in Qualcomm EDL and the next boot is a scarce resource (docs 124).
#
# What it is NOT: a claim that a block works. A block is "COVERED" here only in the sense that some
# script in this tree names it; whether that script's reading is any good is the business of that
# script's own harness. This page measures **the shape of the coverage**, not its quality.
#
# Two derived facts, both re-derived on every run rather than written down:
#
#   1. Which DTB set a block came from. The stock set (5 DTBs, out of the vendor boot image) and
#      the rebuilt set (28 DTBs, out of the Halium build) do **not** describe the same board:
#      the rebuilt set carries 21 nodes the stock set does not (including the v2/v3 SoC family,
#      a second audio amp, a haptics driver, three more touch controllers and the USB-C CC logic),
#      and the stock set carries one the rebuilt set does not (`qcom,msm-thermal-simple`).
#      Both sets also put two generations of display driver on the SAME node (`qcom,mdss_*` and
#      `qcom,sde_*`), so which one binds is decided by the kernel, not by the DTB. **Which set the
#      device boots is therefore a real question with a real answer**, and the only place it can be
#      answered is `/proc/device-tree` on the device -- see --live below.
#   2. Which blocks no script names. The per-block token list is a **curated claim** (a wrong token
#      shows up as a false gap, which is why the harness has a fixture for exactly that); the file
#      column is **measured** by searching the tracked scripts for those tokens, every run.
#
# Usage:
#   zl1-hardware-inventory.sh                      # all blocks + summary
#   zl1-hardware-inventory.sh --gaps               # only the blocks nothing reads
#   zl1-hardware-inventory.sh --block audio        # one block, in full
#   zl1-hardware-inventory.sh --dump-compatibles   # path<TAB>compatible<TAB>sets for the matched nodes
#   zl1-hardware-inventory.sh --snapshot FILE      # read that dump instead of the DTBs (no DTBs needed)
#   zl1-hardware-inventory.sh --table FILE         # use another block table (default: the one below)
#
# --live is the one mode that touches the device, and it is **read-only**: it prints the compatible
# list from `/proc/device-tree` over ssh so the offline sets can be compared against the board that
# is actually here. It does not write, reboot or flash anything.
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DEV="${ZL1_HOST:-root@10.15.19.82}"
PY="${PYTHON:-python3}"

MODE=all
SNAPSHOT=
TABLE_OVERRIDE=
DTB_DIRS=()
DO_LIVE=0
OUT=
while [ $# -gt 0 ]; do
  case "$1" in
  --gaps) MODE=gaps ;;
  --block) MODE=block; ONLY_BLOCK="${2:-}"; shift ;;
  --dump-compatibles) MODE=dump ;;
  --snapshot) SNAPSHOT="${2:-}"; shift ;;
  --dtb-dir) DTB_DIRS+=("${2:-}"); shift ;;
  --dtb) DTB_DIRS+=("${2:-}"); shift ;;
  --live) DO_LIVE=1 ;;
  --table) TABLE_OVERRIDE="${2:-}"; shift ;;
  --out) OUT="${2:-}"; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------------------------
# The block table. One row per piece of hardware a person would call hardware.
#
#   NAME <TAB> DTB pattern (ERE on "<path> <compatibles>") <TAB> instrument tokens <TAB> kind <TAB> instrument
#
# **The separator is a tab, and it is not a pipe on purpose.** The first version of this table used
# `|` as the field separator *and* `|` inside the token alternation, so `read -r a b c d` split the
# row in the wrong places, dumped the rest of the line into `d`, and every row silently took the
# last field as its branch condition. `kind` was never `INFRA` and the DTB pattern was only ever its
# first alternative -- i.e. **the report was wrong about which hardware exists and about which rows
# count**, and it still printed a tidy table. If a field can contain the separator, it is not a
# separator.
#
# **The instrument is named, and the token search only checks the name.** The second version let
# the search pick the instrument, and printed the first file alphabetically -- so the block's *best*
# reader was hidden behind whichever file mentioned it earliest in the alphabet (`modem` was
# credited to `zl1-gps-probe.sh`, which says "the modem's" in a sentence, while the file that
# actually probes the modem was in the same list, one letter later). A name is a claim that can be
# checked: the report prints **STALE** when the named file no longer names the block, so this table
# cannot quietly rot the way a hand-written one does.
#
# kind=INFRA  -- no per-block instrument is meaningful: the block is a bus/clock/regulator that
#                every other driver uses, or (for UFS) the thing the port boots from. Listing these
#                as gaps would bury the real ones.
# kind=HW     -- a device. A row with no named instrument is a **gap**: nothing in this tree has
#                ever looked at it.
#
# The DTB patterns are written against the compatible strings the real DTBs carry, not against what
# the block is usually called: `nq-nci` (not "nfc"), `si4705` (not "fm"), `drv2604` (not
# "vibrator"). A pattern that matches a name nothing uses is a gap that cannot be found, which is
# why a row whose pattern matches no node at all is reported separately instead of counted as
# covered.
# ---------------------------------------------------------------------------------------------
BLOCKS=$(cat <<'TABLE'
display-panel	mdss_dsi|dsi-display|sde_dsi|dsi-ctrl-hw|dsi-phy|mdss-fb	compositor|/dev/dri|DSI|dsi_ctrl|mdss-fb	HW	scripts/device/zl1-egl-probe.py
display-mdp	mdss_mdp|mdss_rotator|mdss_wb|mdss-fb|smmu_mdp|smmu_rot	EGL|compositor|hwcomposer|mdss	HW	scripts/host/zl1-camera-app-test.sh
gpu	kgsl-3d0|kgsl-iommu|kgsl-smmu|kgsl-busmon|kgsl-hyp|gpucc|gpu-mempool	kgsl|/dev/kgsl|/dev/dri|EGL|vsimd	HW	scripts/device/zl1-egl-probe.py
touch	focaltech|synaptics|atmel_mxt|hideep	/dev/input|ABS_MT|BTN_TOUCH|event[0-9]	HW	scripts/device/zl1-watch-input.py
keys	gpio-keys|gpio_keys|qpnp-power-on|pmic-reset-reason	/dev/input|BTN_TOUCH|KEY_|BTN_POWER	HW	scripts/device/zl1-input-devices.py
fingerprint	goodix|fingerprint	goodix|fpdata|biometryd|fingerprint	HW	scripts/device/zl1-fingerprint-probe.sh
nfc	qcom,nq-nci|nq@28	nfcnci|nq-nci|nfc_	HW	-
fm-radio	silabs,si4705	si4705|fm_radio|fmradio	HW	-
vibrator	ti,drv2604	drv2604|vibrat|timed_output|haptic	HW	-
torch	qcom,camera-flash|qpnp-flash-led	camera-flash|flash-led|torch|leds@d300	HW	scripts/device/zl1-leds-probe.sh
backlight	qpnp-wled	backlight|wled|brightness	HW	scripts/hybris-shims/free-container-display.sh
notification-led	qcom,leds-qpnp	leds-qpnp|led_classdev|/sys/class/leds	HW	scripts/device/zl1-leds-probe.sh
audio-codec	msm-dai|wcd9|max98927|tfa9890|audio-codec|msm-cpe|msm-audio-ion|audio-ref-clk	max98927|tasha|smartpa|mixer_paths|pulseaudio|tinymix|snd_device|TERT_MI2S	HW	scripts/device/zl1-audio-test.sh
camera	cci@|csiphy|csid|vfe|jpeg@|cpp@|actuator|eeprom|ois|ispif|camera@	camera|ICameraProvider|cameraserver|camapp	HW	scripts/host/zl1-camera-app-test.sh
video-codec	msm-vidc|vidc@|venus@	vidc|venus|v4l2|mediacodec	HW	-
wifi	qcom,cnss|qcom,pci-msm|qca6174|wlan_en	cnss|qca6174|wlan|fwpath|wifi|icnss	HW	scripts/hybris-shims/install-wlan-bringup.sh
bluetooth	qca,qca6174|bt_qca	bluetooth|bluetoothd|bt_qca|hciattach|bluez	HW	scripts/hybris-shims/install-container-ns-services.sh
modem	qcom,mhi|qcom,ipa|glink-smem-native-xprt-modem|ipc_router_modem	mhi|rmnet|ipa|modem|ofono|ril_|telephony	HW	scripts/device/zl1-modem-probe.sh
sensors	qcom,msm-ssc-sensors|qcom,sensor-information|qcom,ssc@|glink-ssr-dsps	sensorfwd|sensor|accelerometer|proximity|als_	HW	scripts/device/zl1-sensorfw-probe.sh
thermal-tsens	qcom,msm8996-tsens|tsens@	tsens|thermal_zone|/sys/class/thermal	HW	scripts/device/zl1-thermal.sh
thermal-lmh	qcom,lmh	lmh	HW	scripts/device/zl1-lmh-probe.sh
thermal-policy	qcom,msm-thermal|qcom,msm-thermal-simple|qpnp-temp-alarm|adc-tm	qcom,thermal|thermal|cpufreq|scaling_governor|throttle	HW	scripts/install-cpufreq-governor.sh
battery	qcom,smb1351-charger|qpnp-smbcharger|qpnp-vadc|qpnp-rtc|coincell	charger|battery|voltage_now|capacity|power_supply	HW	scripts/device-readonly-inventory.sh
usb	qcom,dwc-usb3-msm|snps,dwc3|qcom,qusb2phy|qcom,android-usb|qcom,usb-bam|qcom,usb-dbm	rndis|dwc3|/sys/class/power_supply/usb	HW	scripts/host/zl1-rndis-recover.sh
usb-pd	tusb302l|tusb320|pi5usb|cypress,cyccg|analogix,ohio|analogix,anx7816	tusb|typec|usb_pd|cclogic|cclogic_dev	HW	-
sdcard	qcom,sdhci-msm	sdhci|mmcblk|/dev/mmcblk	HW	-
wfd	mdss_fb_wfd|mdss_wb	wfd|miracast|writeback	HW	-
hdmi	qcom,hdmi-tx|qcom,hdmi-display|qcom,hdmi-tx-8996|mdss_hdmi_pll|hdmi-audio	HDMI|hdmi	HW	-
eeprom	atmel,24c32	24c32|at24|nvmem|eeprom	HW	-
ufs	jedec,ufs-1.1|qcom,ufs-phy|qcom,ice	ufshc|ufs-phy|/sys/block	INFRA	-
coresight	coresight|etm@|etm0|tpda|tpdm	coresight|stm_|etm|trace	INFRA	-
interconnect	qcom,rpm-smd-regulator|qcom,gcc@|qcom,mmsscc|qcom,gpucc|qcom,cpr3|rpm-glink|rpm-log	clk|regulator	INFRA	-
ipc	qcom,glink|qcom,ipc_router|qcom,smem|qcom,smp2p|qcom,smd	glink|ipc_router|smem|smp2p|qmi	INFRA	-
pinctrl	pinctrl|qcom,tlmm	pinctrl|gpio	INFRA	-
iommu	arm,smmu|qcom,kgsl-smmu|qcom,smmu	smmu|iommu	INFRA	-
TABLE
)
# `--table` replaces the table above. It is a real option, not a test hook: the block patterns are the
# one part of this report that is a claim rather than a measurement, and running a different table is
# how the claim gets tested -- and how a different board could be inventoried with the same instrument
# search. The harness uses it; so could a future device.
[ -n "${TABLE_OVERRIDE:-}" ] && BLOCKS=$(cat "$TABLE_OVERRIDE")

# A table row is five tab-separated fields, and a row that is not is REFUSED rather than classified.
# This is not defensive: the first `--table` run of a four-field row put the instrument name where the
# kind belongs, left the instrument field empty -- and an empty pattern makes `grep -x` match every
# line, so the block was reported COVERED with a blank instrument column and the summary said
# "1 with a named instrument, 0 with none". A malformed input silently inverted the answer, which is
# the same shape as everything else this tree has had to fix. Count the fields, then fail.
TABLE_BAD=$(printf '%s\n' "$BLOCKS" | awk -F'\t' 'NF && NF != 5 {print NR": "NF" field(s)"}')
if [ -n "$TABLE_BAD" ]; then
  echo "the block table is not 5 tab-separated fields per row:" >&2
  printf '  %s\n' "$TABLE_BAD" >&2
  echo "  NAME <TAB> DTB-pattern <TAB> instrument-tokens <TAB> kind <TAB> instrument" >&2
  exit 2
fi

# ---------------------------------------------------------------------------------------------
# The FDT walker. One pass per file; every node that carries a `compatible`.
#
# Two things in here were wrong on the first attempt and are worth keeping visible:
#   * FDT_END is token **9**, not 4. 4 is FDT_NOP. Reading 4 as END bounds the walk early;
#     reading 9 as unknown aborts it -- which is how the first run of this parser failed
#     (`bad token 9`) after 2105 nodes had already parsed, i.e. it looked like it worked.
#   * property padding is `(len + 3) & ~3`. `(len + 4) & ~3` is the same expression with `+`
#     binding tighter than `&`, and it misaligns the token stream by one byte every time a
#     property's length is a multiple of 4 -- so the walk returns a plausible, short tree.
# ---------------------------------------------------------------------------------------------
walker() {
  "$PY" - "$@" <<'PYEOF'
import struct, sys, os

MAGIC = 0xd00dfeed
def be(b, off, n): return int.from_bytes(b[off:off+n], 'big')

def cstr(b, off):
    end = b.index(b'\0', off)
    return b[off:end].decode('utf-8', 'replace')

def walk(b):
    if be(b, 0, 4) != MAGIC:
        raise ValueError('not an FDT (magic=%08x)' % be(b, 0, 4))
    off_struct, off_strings = be(b, 8, 4), be(b, 12, 4)
    i, stack = off_struct, []
    while i < off_strings:
        tok = be(b, i, 4); i += 4
        if tok == 1:                                  # FDT_BEGIN_NODE
            j = i
            while b[j] != 0: j += 1
            name = b[i:j].decode('utf-8', 'replace')
            i = (j + 1 + 3) & ~3
            stack.append(name)
        elif tok == 2:                                # FDT_END_NODE
            if stack: stack.pop()
        elif tok == 3:                                # FDT_PROP
            ln, noff = be(b, i, 4), be(b, i+4, 4); i += 8
            pname = cstr(b, off_strings + noff)
            val = b[i:i+ln]
            i = (i + ln + 3) & ~3                     # <- not (ln + 4)
            if pname == 'compatible' and ln:
                cs = [s.decode('utf-8', 'replace') for s in val.rstrip(b'\0').split(b'\0')]
                yield '/' + '/'.join(p for p in stack if p), cs
        elif tok == 4:                                # FDT_NOP
            continue
        elif tok == 9:                                # FDT_END
            break
        else:
            raise ValueError('bad token %d at %d' % (tok, i - 4))

for path in sys.argv[1:]:
    if os.path.isdir(path):
        print('PARSE-FAILED\t%s\tis a directory, not a device tree' % path, file=sys.stderr)
        sys.exit(3)
    if not os.access(path, os.R_OK):
        print('PARSE-FAILED\t%s\tnot readable' % path, file=sys.stderr)
        sys.exit(3)
    # The set name is how a block's provenance is reported, so it has to be able to tell `stock`
    # from `rebuilt` -- both live in a directory called `dtbs`, 5 against 28, and they do not
    # describe the same board. One letter each, because the column is narrow and the meaning is in
    # the header; anything else keeps its directory name rather than being forced into a code.
    d = os.path.dirname(os.path.abspath(path))
    base = os.path.basename(d)
    parent = os.path.basename(os.path.dirname(d))
    if parent == 'stock':
        setname = 'S'
    elif parent == 'rebuilt':
        setname = 'R'
    elif base.startswith('tmp-dtb'):
        setname = 'F'
    else:
        setname = base
    b = open(path, 'rb').read()
    try:
        for p, cs in walk(b):
            for c in cs:
                print('%s\t%s\t%s' % (p, c, setname))
    except ValueError as e:
        # Louder than a traceback would be usefully: a DTB that does not parse is a hole in the
        # inventory, and the caller must be able to see which one.
        print('PARSE-FAILED\t%s\t%s' % (path, e), file=sys.stderr)
        sys.exit(3)
PYEOF
}

# Where the DTBs are. Both are `tmp-*/`, i.e. **gitignored**: they are scratch from an earlier
# extraction, and a fresh clone has neither. That is the reason --snapshot exists.
find_dtbs() {
  # A --dtb-dir is a DIRECTORY and expands to the .dtb files in it; a --dtb is used as given. The first
  # version passed the directory itself to the parser, which read a directory as a file: the run printed
  # an empty tree with `IsADirectoryError` on stderr and exit 0 through a pipe, i.e. it looked like a
  # device tree with no hardware. The harness's "the dump has content" check is what caught it.
  if [ ${#DTB_DIRS[@]} -gt 0 ]; then
    local e found=0
    for e in "${DTB_DIRS[@]}"; do
      if [ -d "$e" ]; then
        find "$e" -maxdepth 1 -name '*.dtb' -print 2>/dev/null | sort
        found=1
      elif [ -f "$e" ]; then
        printf '%s\n' "$e"
        found=1
      else
        echo "no such device tree or directory: $e" >&2
      fi
    done
    [ "$found" = 1 ] || { echo "none of the --dtb-dir/--dtb arguments named anything readable" >&2; return 3; }
    return 0
  fi
  local d
  for d in "$ROOT"/tmp-dtb-analysis/stock/dtbs "$ROOT"/tmp-dtb-analysis/rebuilt/dtbs "$ROOT"/tmp-dtb-filtered; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -name '*.dtb' -print 2>/dev/null | sort
  done
}

collect() {
  if [ -n "$SNAPSHOT" ]; then
    [ -f "$SNAPSHOT" ] || { echo "no such snapshot: $SNAPSHOT" >&2; exit 2; }
    # Comments and the header record the provenance; the data lines are the triples.
    grep -vE '^[[:space:]]*(#|$)' "$SNAPSHOT"
    return 0
  fi
  local files count=0
  files=$(find_dtbs)
  if [ -z "$files" ]; then
    cat >&2 <<'MSG'
No device trees found and no --snapshot given.

  The DTBs live under tmp-*/ (gitignored scratch) and a fresh clone has none. Either point at
  them:

      zl1-hardware-inventory.sh --dtb-dir /path/to/dtbs

  or use the committed snapshot, which is the same data with its provenance in the header:

      zl1-hardware-inventory.sh --snapshot docs/ubuntu-touch/hardware-compatibles.txt

  The snapshot is derived, not authoritative: if you have the DTBs, use the DTBs.
MSG
    exit 2
  fi
  count=$(printf '%s\n' "$files" | wc -l)
  echo "# source: $count dtb files from $(printf '%s\n' "$files" | xargs -r -n1 dirname | sort -u | tr '\n' ' ')" >&2
  # shellcheck disable=SC2086
  walker $files
}

# The instrument search. `scripts/` only, and three kinds of line/file are excluded, each because
# the first run of this script counted it and was wrong:
#
#   * **this script** -- it carries every token in its table, so it matched every block and reported
#     "34 with an instrument, **0 with none**": a report that cannot report a gap, which is the same
#     defect as an unread write ([[zl1-instruments-that-cannot-report-not-armed]]).
#   * **harness files** (`*selftest*`) -- a harness names its subject's tokens because it is testing
#     the subject, so counting it would let a block look covered on the strength of the very file
#     that proves it is not.
#   * **the backup allowlists** (`backup-partitions-*`) -- their `ALLOWLIST` names eight partitions,
#     and three of those names are also hardware block names (`modem`, `dsp`, `bluetooth`). A list of
#     partition names is not an instrument, and this one made two real gaps look covered.
#
# and then, on lines: a name in a **comment** or in a **printed string** is prose, not a reading.
# Two gaps disappeared on the first run purely because of prose -- `vibrator` matched the word
# "haptics" in a file's opening paragraph, and `video-codec` matched "venus" in another's. This is
# the same filter the family's own census needed (docs 136 s5), for the same reason.
instrument_files() {
  local toks="$1"
  ( cd "$ROOT" && grep -rnE --include='*.sh' --include='*.py' -- "$toks" scripts/ 2>/dev/null ) |
    grep -v 'selftest' |
    grep -v 'scripts/host/zl1-hardware-inventory' |
    grep -v 'scripts/backup-partitions' |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(always|say|echo|printf|log|warn|die)[[:space:]]+["'"'"']' |
    cut -d: -f1 | sort -u
}

main_report() {
  local data block dtbpat toks kind named
  data=$(collect) || exit $?
  local total_nodes total_paths total_sets
  # Pairs and paths are different counts and the difference is not noise: a node can carry several
  # compatibles (the display nodes carry two driver generations each), and a path can appear twice
  # in one DTB (`/soc/wlan_en_vreg` does). Printing only one of the two would make the other look
  # like a bug in whichever run showed it.
  total_nodes=$(printf '%s\n' "$data" | cut -f1,2 | sort -u | wc -l)
  total_paths=$(printf '%s\n' "$data" | cut -f1 | sort -u | wc -l)
  # Every set column goes through this, so the snapshot and the DTBs give the same answer. They
  # disagree naturally: one DTB line carries one set, a merged snapshot line carries several, and a
  # block can match several node/compatible pairs -- so the same fact arrives as `F`,`R`,`S` on one
  # path and as `F R S`,`R` on the other. Sorting the *tokens* makes the two indistinguishable.
  norm_sets() { tr ' ' '\n' | grep . | sort -u | tr '\n' ' ' | sed 's/ $//'; }
  total_sets=$(printf '%s\n' "$data" | cut -f3 | norm_sets)

  if [ "$MODE" = dump ]; then
    # The snapshot is what makes this report checkable on a fresh clone: the DTBs are `tmp-*/`
    # and gitignored (15 MB, and derived), so without a snapshot the coverage claim in the doc
    # would be unfalsifiable a month from now. It carries its own provenance, so a reader can see
    # which files it came from and prove it against them if the DTBs are still around.
    printf '# zl1 device-tree compatibles -- GENERATED by scripts/host/zl1-hardware-inventory.sh\n'
    printf '# Regenerate:  zl1-hardware-inventory.sh --dump-compatibles > this-file\n'
    printf '# Columns: path <TAB> compatible <TAB> set   (S=stock R=rebuilt F=filtered)\n'
    printf '# This is a derived subset: nodes carrying a `compatible`, which is every block the\n'
    printf '# kernel can bind. Nodes without one (memory reservations, chosen, aliases) are omitted.\n'
    local f d
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      d=$(dirname "$f")
      printf '#   source %-58s %10s bytes  sha256=%s\n' "${f#"$ROOT"/}" "$(stat -c%s "$f")" \
        "$(sha256sum "$f" | cut -d' ' -f1)"
    done <<< "$(find_dtbs)"
    printf '# totals: %s distinct paths, %s path/compatible pairs, sets: %s\n' "$total_paths" "$total_nodes" "$total_sets"
    # One line per (path, compatible), with the sets merged. Without this the snapshot is 38
    # copies of the same tree (1.4 MB, 26000 lines) because all 38 DTBs describe most of the same
    # board -- which is the fact the SETS column exists to show, and it shows it better merged.
    # The letters are sorted so the file does not change when the --dtb-dir order does.
    # Dedupe by SET NAME, not by character. The first version concatenated the letters and deduped
    # characters, which is only correct while every set name is one letter -- run against two scratch
    # directories (`dtbs`, `dtbs2`) it produced the set `2bdst`, which is not a set. The names are
    # words here and stay words.
    printf '%s\n' "$data" | awk -F'\t' '
      { k = $1 "\t" $2
        if (!(k in seen)) { order[++n] = k; seen[k] = "" }
        if (index(seen[k], "\t" $3 "\t") == 0) seen[k] = seen[k] "\t" $3 }
      END { for (i = 1; i <= n; i++) {
              m = split(seen[order[i]], a, "\t"); c = 0
              for (j = 1; j <= m; j++) {
                if (a[j] == "") continue
                dup = 0
                for (x = 1; x <= c; x++) if (u[x] == a[j]) dup = 1
                if (!dup) u[++c] = a[j] }
              do { sw = 0
                   for (j = 1; j < c; j++) if (u[j] > u[j+1]) { t = u[j]; u[j] = u[j+1]; u[j+1] = t; sw = 1 } }
              while (sw)
              d = ""
              for (j = 1; j <= c; j++) { d = d u[j]; if (j < c) d = d " " }
              printf "%s\t%s\n", order[i], d
              delete u } }'
    return 0
  fi

  local report
  report=$(
    echo "zl1 hardware inventory -- derived from the device's own device trees"
    echo "  source sets:   $total_sets"
    echo "  nodes in the device tree: $total_paths distinct paths, $total_nodes path/compatible pairs"
    echo "  SETS: S=stock (vendor boot image) R=rebuilt (Halium build) F=filtered (patched stock)."
    echo "        A block in one set and not another is a block whose existence depends on which"
    echo "        image boots; the device's own answer is /proc/device-tree, i.e. --live."
    echo
    printf '%-16s %-5s %-38s %s\n' BLOCK DTB INSTRUMENT SETS
    printf '%-16s %-5s %-38s %s\n' --------- ----- ---------------------------------------- ----
  )
  local covered=0 gap=0 infra=0 nstale=0 gapwall="" nodewall="" stalewall=""
  while IFS=$'\t' read -r block dtbpat toks kind named; do
    [ -n "$block" ] || continue
    if [ "$MODE" = block ] && [ "$block" != "${ONLY_BLOCK:-}" ]; then continue; fi
    local nodes sets n=0 files nfiles=0 shown others
    nodes=$(printf '%s\n' "$data" | awk -F'\t' -v p="$dtbpat" 'tolower($1" "$2) ~ tolower(p) {print $1"\t"$2}' | sort -u)
    [ -n "$nodes" ] && n=$(printf '%s\n' "$nodes" | wc -l)
    sets=$(printf '%s\n' "$data" | awk -F'\t' -v p="$dtbpat" 'tolower($1" "$2) ~ tolower(p) {print $3}' | norm_sets)
    files=$(instrument_files "$toks")
    [ -n "$files" ] && nfiles=$(printf '%s\n' "$files" | wc -l)
    if [ "$kind" = INFRA ]; then
      infra=$((infra + 1))
      continue
    fi
    # A row whose DTB pattern matches no node at all is not a covered block: it is a broken
    # pattern, and it is reported as its own thing rather than counted as either.
    if [ "$n" -eq 0 ]; then
      nodewall="${nodewall}${block}|${dtbpat}
"
      continue
    fi
    # Three verdicts, and the difference between the last two is the point:
    #   COVERED -- the named file exists AND names the block.
    #   STALE   -- the named file is **not there**. The table's path is wrong; that is a defect in the
    #              table, and it is reported as its own thing because it is the one failure a
    #              hand-written table cannot escape and a re-derived one cannot have.
    #   NONE    -- nothing names the block, whether because the row says `-` or because the named file
    #              is there but only mentions it in prose. **This is the gap**, and calling the second
    #              case STALE would be wrong: the file may be exactly the right probe and still not
    #              read this block, which is the whole question this report asks.
    if [ -z "$named" ] || [ "$named" = "-" ]; then
      gap=$((gap + 1))
      shown="**NONE**"
      gapwall="${gapwall}${block}|${n}|${sets}|-
"
    elif [ ! -e "$ROOT/$named" ]; then
      nstale=$((nstale + 1))
      stalewall="${stalewall}${block}|${named}
"
      shown="STALE: ${named##*/}"
    elif grep -qx -- "$named" <<< "$files"; then
      covered=$((covered + 1))
      others=$((nfiles - 1))
      # Basename, not path: the longest real name here (`install-container-ns-services.sh`, 47 chars
      # with its directory) would overflow the column and get cut mid-suffix, which reads like a
      # defect rather than a truncation. The full path is in --block NAME.
      shown="${named##*/}"
      if [ "$others" -gt 0 ] && [ $(( ${#shown} + 6 )) -le 38 ]; then
        shown="$shown (+$others)"
      fi
    else
      gap=$((gap + 1))
      shown="**NONE**"
      gapwall="${gapwall}${block}|${n}|${sets}|${named}
"
    fi
    # The literal newline in front matters: $( ) strips the header's trailing newline, so without
    # it every row would be appended to the last header line.
    report="${report}
$(printf '%-16s %-5s %-38s %s\n' "$block" "$n" "$(printf '%s' "$shown" | cut -c1-38)" "$sets")"
  done <<< "$BLOCKS"

  report="${report}
$(printf '%-16s %-5s %-38s %s\n' '-----' '-----' '----------------------------------------' '----')
blocks: $((covered + gap + nstale)) hardware -- $covered with a named instrument, **$gap with none**, $nstale STALE; plus $infra infrastructure rows, which need no instrument of their own"
  if [ "$gap" -gt 0 ]; then
    report="${report}

No script in this tree names these blocks:
$(printf '%s' "$gapwall" | while IFS='|' read -r b n s f; do
          [ -n "$b" ] || continue
          [ "$f" = "-" ] && printf '  %-16s %s dtb node(s), in %s\n' "$b" "$n" "$s" ||
            printf '  %-16s %s dtb node(s), in %s -- %s names it only in prose\n' "$b" "$n" "$s" "${f##*/}"
        done)"
  fi
  if [ "$nstale" -gt 0 ]; then
    report="${report}

Claimed instruments that no longer name their block -- the table has rotted:
$(printf '%s' "$stalewall" | while IFS='|' read -r b f; do [ -n "$b" ] && printf '  %-16s %s\n' "$b" "$f"; done)"
  fi
  if [ -n "$nodewall" ]; then
    report="${report}

Rows whose DTB pattern matched no node -- a broken pattern, not a missing block:
$(printf '%s' "$nodewall" | while IFS='|' read -r b p; do [ -n "$b" ] && printf '  %-16s %s\n' "$b" "$p"; done)"
  fi
  if [ "$MODE" = gaps ]; then
    printf '%s\n' "$report" | sed -n '/with none/,$p'
  else
    printf '%s\n' "$report"
  fi
  if [ -n "$OUT" ]; then printf '%s\n' "$report" >"$OUT"; fi
}

live() {
  # Read-only, and the only mode that goes near the device. `/proc/device-tree` is the tree the
  # *running* kernel was handed: it settles which of the offline sets the board actually boots,
  # which is the one question the DTBs on this host cannot answer about themselves.
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 "$DEV" '
      [ -r /proc/device-tree/compatible ] || { echo "no /proc/device-tree -- not a live device" >&2; exit 1; }
      printf "  root compatible: %s\n" "$(tr "\0" " " < /proc/device-tree/compatible)"
      printf "  model:           %s\n" "$(tr -d "\0" < /proc/device-tree/model 2>/dev/null)"
      echo "  nodes with a compatible:"
      find /proc/device-tree -name compatible -type f 2>/dev/null | while read -r f; do
        printf "    %-56s %s\n" "${f#/proc/device-tree}" "$(tr "\0" " " < "$f")"
      done | sort | head -400'
}

if [ "$DO_LIVE" = 1 ]; then
  live
  exit $?
fi

main_report

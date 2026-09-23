#!/bin/sh
# zl1-audio-test -- put a known tone into the speaker and read back what the codec was told to do.
#
# Why this exists: the user asked for **"音频：让扬声器真的出声"**. Everything up to the speaker can be
# verified from software, and this script verifies all of it; the one thing it cannot do is hear the
# result, so it is built to be run while a human is holding the phone.
#
# The chain on this port, and how each link is checked here:
#
#   paplay -> pulseaudio sink.primary_output   (module-droid-card, Active Port output-speaker)
#          -> android.hardware.audio@2.0-service in the container   (via module-droid-hidl)
#          -> snd_device(2: speaker-stereo) + mixer path "low-latency-playback smartpa"
#          -> the MSM8996 `TERT_MI2S_RX` backend -- i.e. the audio leaves the SoC over the
#             **tertiary MI2S** to an external smart amplifier, not through the internal WCD9335
#             speaker PA. The amplifier's own controls live in the `speaker` path of
#             /vendor/etc/mixer_paths_tasha.xml (Speaker Volume, Digital Gain, Boost Output
#             Voltage, channel and feedback enables) and are read back here with the Android
#             `tinymix`.
#
#             The tool matters, not the namespace: the **host's `amixer` cannot read this card**
#             (`amixer -c 0` -> "Mixer load sysdefault:0 error: No such device", and even `amixer
#             -c 0 info` reports an empty mixer name), but `/system/bin/tinymix` runs straight
#             from the host -- Halium symlinks `/system -> /android/system` -- and prints all 2392
#             controls. So no `nsenter` is needed here, and none was used for the numbers below.
#             (Contrast the sensors HAL, which really does need the container's PID namespace.)
#
# What a run tells you:
#   * playback symptom "no sound but the sink went RUNNING" -> look at the codec block. If
#     `TERT_MI2S_RX Audio Mixer MultiMedia5` is On and the speaker gains are set, the software
#     side did its job and the silence is downstream of the codec (the external amp, its power,
#     or its I2C firmware) -- nothing left in PulseAudio/the HAL to fix.
#   * symptom "the sink never leaves SUSPENDED" -> the problem is above the HAL (routing, the
#     droid module, or the wrong sink), and the codec block will be at its idle defaults
#     (Speaker Volume 1, Boost 6.5V) because the mixer path was never applied.
#
# Usage (on the device): zl1-audio-test.sh [--seconds N] [--hz F] [--amp A] [--sink NAME] [--status]
#   --seconds N   length of the tone (default 10)
#   --hz F        frequency (default 440)
#   --amp A       amplitude 0..32767 (default 24000; the earlier 12000 was inaudibly quiet on a
#                 speaker, which is itself a thing worth not mistaking for a hardware fault)
#   --sink NAME   default sink.primary_output (the droid card's speaker port)
#   --status      play nothing; just report the sink state and the codec's speaker controls
#
# Writes only to /tmp on the device, plays through the normal PulseAudio path, and touches no
# persistent state.

set -u

SECONDS_TONE=10
HZ=440
AMP=24000
SINK=sink.primary_output
STATUS_ONLY=0
WAV=/tmp/zl1-audio-test.wav

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) SECONDS_TONE="$2"; shift 2 ;;
    --hz)      HZ="$2"; shift 2 ;;
    --amp)     AMP="$2"; shift 2 ;;
    --sink)    SINK="$2"; shift 2 ;;
    --status)  STATUS_ONLY=1; shift ;;
    # --help prints this file's own header: the header IS the manual (it carries the Usage line),
    # and the length of it is not something a fixed line range can know.
    --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
    *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

# Everything that needs to talk to pulseaudio runs as phablet: the pulse socket lives in
# /run/user/32011 and root is refused ("XDG_RUNTIME_DIR is not owned by us").
as_phablet() {
  su -l phablet -c "export XDG_RUNTIME_DIR=/run/user/32011; $1"
}

# The codec's control interface, read with the Android tool (see the note at the top: the host's
# amixer cannot load this card's mixer, and no namespace change is involved in the working path).
mixer() {
  /system/bin/tinymix 2>/dev/null
}

show_speaker_controls() {
  echo "--- codec state for the speaker (Android tinymix, read from the host) ---"
  mixer | grep -iE 'TERT_MI2S_RX Audio Mixer MultiMedia5|Speaker Volume|Digital Gain|Boost Output Voltage|Left Channel Enable|Right Channel Enable|Feedback Enable|SPKR_VI' || true
}

show_status() {
  echo "=== pulseaudio sinks ==="
  as_phablet 'pactl list short sinks'
  echo
  echo "=== the default sink's port ==="
  as_phablet 'pactl list sinks | grep -E "Name: sink.primary_output" -A12 | grep -E "State:|Active Port:|Mute:|Volume:"'
  echo
  show_speaker_controls
  echo
  echo "=== which host PCM the kernel says is running (should be empty when idle) ==="
  for f in /proc/asound/card0/pcm*/sub0/status; do
    s=$(grep -m1 state "$f" 2>/dev/null)
    case "$s" in *RUNNING*) echo "  $f: $s" ;; esac
  done
}

if [ "$STATUS_ONLY" = 1 ]; then
  show_status
  exit 0
fi

echo "=== generating a ${SECONDS_TONE}s ${HZ}Hz tone (amplitude ${AMP}) ==="
python3 - "$WAV" "$SECONDS_TONE" "$HZ" "$AMP" <<'PY'
import math, struct, sys, wave
path, secs, hz, amp = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
w = wave.open(path, 'w'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
frames = bytearray()
for i in range(44100 * secs):
    v = int(amp * math.sin(2 * math.pi * hz * i / 44100.0))
    frames += struct.pack('<hh', v, v)
w.writeframes(bytes(frames)); w.close()
print("  wrote %s" % path)
PY
chmod 644 "$WAV"; chown phablet:phablet "$WAV"

echo "=== playing through $SINK ==="
as_phablet "nohup paplay --device=$SINK $WAV >/tmp/zl1-audio-paplay.out 2>&1 &"

sleep 2
echo "--- sink state during playback (RUNNING = pulseaudio is feeding the HAL) ---"
as_phablet 'pactl list short sinks'
echo
show_speaker_controls
echo
echo "--- running PCMs on the host ---"
for f in /proc/asound/card0/pcm*/sub0/status; do
  s=$(grep -m1 state "$f" 2>/dev/null)
  case "$s" in *RUNNING*) echo "  $f: $s" ;; esac
done

# Wait out the rest of the tone, then show what the HAL leaves behind. The `speaker` path is
# un-applied at standby, so these values reverting to the idle defaults is expected and is the
# control that the block above is really the playback configuration.
remaining=$((SECONDS_TONE - 2 + 6))
[ "$remaining" -gt 0 ] && sleep "$remaining"

echo
echo "=== paplay said (empty = no error) ==="
cat /tmp/zl1-audio-paplay.out 2>/dev/null || true
echo "=== after playback ==="
as_phablet 'pactl list short sinks'
echo
show_speaker_controls
echo
echo "If the codec block above showed MultiMedia5 On with the speaker gains set while it played,"
echo "the software path is complete and any remaining silence is downstream (the external amp)."
echo "Whether any sound was audible is the one thing this script cannot measure -- ask the human."

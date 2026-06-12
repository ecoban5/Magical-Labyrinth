"""Offline render of the Web Audio synth from labyrinth3d.html to WAV files
for the Godot port. Reproduces playNote's envelope and oscillator types.
Outputs: godot/audio/melody.wav (loopable), portal.wav, fanfare.wav
"""
import math
import os
import random
import struct
import wave

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "audio")

DORIAN_D = [293.66, 329.63, 349.23, 392.00, 440.00, 493.88,
            523.25, 587.33, 659.25, 698.46, 784.00, 880.00]
MELODY = [(0,.5),(2,.5),(3,.5),(5,.5),(7,.5),(5,.5),(3,.5),(2,.5),(0,1),(0,.5),(2,.5),
          (3,.5),(5,.5),(7,.5),(8,.5),(7,.5),(5,.5),(3,.5),(2,.5),(0,1.5),
          (3,.5),(5,.5),(7,.5),(5,.5),(3,1),(2,.5),(0,.5),(2,.5),(3,.5),(5,.5),(7,.5),(5,.5),(3,.5),(2,.5),(0,.5),(0,2)]
DRONE_NOTES = [73.42, 110.00, 146.83]


def osc(wave_type, freq, t):
    ph = (freq * t) % 1.0
    if wave_type == "sine":
        return math.sin(2 * math.pi * ph)
    if wave_type == "square":
        return 1.0 if ph < 0.5 else -1.0
    if wave_type == "sawtooth":
        return 2.0 * ph - 1.0
    # triangle
    return 4.0 * abs(ph - 0.5) - 1.0


def add_note(buf, freq, start, dur, vol=0.12, wave_type="triangle"):
    """Mirror of playNote: 0.04s linear attack, hold to dur*0.7, release to dur."""
    n0 = int(start * SR)
    n1 = min(int((start + dur) * SR), len(buf))
    for i in range(n0, n1):
        t = i / SR - start
        if t < 0.04:
            env = vol * t / 0.04
        elif t < dur * 0.7:
            env = vol
        else:
            env = vol * max(0.0, (dur - t) / (dur * 0.3))
        buf[i] += env * osc(wave_type, freq, i / SR)


def write_wav(name, buf):
    peak = max(1e-9, max(abs(s) for s in buf))
    scale = min(1.0, 0.92 / peak)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(s * scale * 32767)) for s in buf))
    print(f"wrote {path} ({len(buf)/SR:.1f}s)")


def render_melody():
    random.seed(7)  # deterministic harmony pattern
    tempo = 1.2
    total = sum(b for _, b in MELODY) * tempo
    buf = [0.0] * int((total + 0.2) * SR)
    t = 0.0
    for ni, beats in MELODY:
        dur = beats * tempo
        add_note(buf, DORIAN_D[ni], t, dur, 0.10, "triangle")
        if random.random() > 0.5:
            add_note(buf, DORIAN_D[min(ni + 4, len(DORIAN_D) - 1)], t, dur, 0.04, "sine")
        t += dur
    for f in DRONE_NOTES:
        add_note(buf, f, 0.0, total, 0.04, "sawtooth")
    write_wav("melody.wav", buf[:int(total * SR)])  # trim for seamless loop


def render_portal():
    buf = [0.0] * int(1.0 * SR)
    sweep = [220, 330, 494, 740, 1109, 880, 660]
    for i, f in enumerate(sweep):
        add_note(buf, f, 0.02 + i * 0.055, 0.18, 0.09, "sine")
    for i, f in enumerate([1320, 1760, 2093]):
        add_note(buf, f, 0.32 + i * 0.07, 0.15, 0.05, "triangle")
    write_wav("portal.wav", buf)


def render_fanfare():
    ff = [(392,.15),(523,.15),(659,.15),(784,.4),(784,.15),(880,.15),
          (784,.15),(659,.4),(523,.2),(659,.2),(784,.6)]
    total = sum(d + 0.02 for _, d in ff) + 0.3
    buf = [0.0] * int(total * SR)
    t = 0.1
    for f, d in ff:
        add_note(buf, f, t, d, 0.18, "square")
        t += d + 0.02
    write_wav("fanfare.wav", buf)


if __name__ == "__main__":
    render_melody()
    render_portal()
    render_fanfare()

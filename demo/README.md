# Demo video material

Everything needed to reproduce the demo video, minus the media itself.

## Why there is no video in here

The captures come to roughly 365 MB — 265 MB of it H.264. Git keeps every
version forever and every clone pays for it, so the media is deliberately not
committed. Publish finished cuts as GitHub Release assets; keep working
footage local.

## What is here

| Path | What it is |
|---|---|
| `shooting-script.html` | The shooting script. Timecoded beats, exact narration, visual direction, and the three asks. Open it in a browser. |
| `narration/clips.txt` | Narration per clip, `name\|text`. |
| `narration/boot-video.txt` | Timed cues for the phone-filmed boot video, `seconds\|text`. |
| `narration/screen-recording.txt` | Timed cues for the screen recording, `seconds\|text`. |
| `measurements/` | Raw `dumpsys SurfaceFlinger --timestats` dumps and the terminal proof block. |
| `tools/annotate.py` | Dims a screenshot, spotlights regions, adds callouts. |

## Reproducing the edit

Rootless, no sudo. `ffmpeg` and `espeak-ng` were installed by unpacking debs
into a prefix and putting wrappers on `PATH`; Kdenlive is an AppImage.

Generate a narration track from a cue file and mux it at the right offsets:

```sh
while IFS='|' read -r t text; do
    espeak-ng -v en-gb -s 148 -p 40 -g 6 -w "tts_$t.wav" "$text"
done < demo/narration/screen-recording.txt
```

Then one `adelay` per cue into a single `amix`.

**Use `duration=longest`, not `duration=first`.** With `first`, amix takes the
first *input's* length — which is a narration cue, not the video — and silently
truncates the whole track. It produced 13.8 s of audio against 93 s of video
and looked fine until the levels were measured.

## Two things the numbers depend on

**Never quote a frame rate from footage you recorded.** SuperTuxKart on iris
measured 1259 frames / 43 s = **29.3 fps** clean, and 511 frames / 41 s =
**12.5 fps** while `screenrecord` was running. The encoder competes with the
game for the GPU and costs about 58 %. Shoot the footage and run the benchmark
as separate takes. Both dumps are in `measurements/` so the difference is
checkable.

**Screen recording needs a property this device does not set by default.**
`debug.stagefright.c2inputsurface=1`, without which `screenrecord` segfaults in
`CCodec::createInputSurface()`. Shipped in `device.mk` as of `75a8b0e`; on an
older image, set it by hand after each boot.

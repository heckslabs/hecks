---
ref: i740
status: open
priority: medium
value: 'video-editing-as-bluebook'
posted_at: 2026-05-24
source: conversation
---

# i740 — video-editing-as-bluebook

A `VideoEditing` bluebook so video edits are terminal-driven, reproducible dispatches through the bus instead of GUI pixel-dragging.

## Motivating case
Editing the YC Pitch in DaVinci Resolve (free edition) : dragging the tiny audio fade handle to set a 20-second fade-out on the founder clip was unreliable through remote screen control (kept catching the trim edge ; the free edition also blocks external scripting). The terminal does it in one line :

    ffmpeg -i intro.mp4 -af "afade=t=out:st=43.55:d=20" -c:v copy intro-faded.mp4

(intro.mp4 is 63.55s ; a 20s fade-out starts at 43.55s.) That one-liner is exactly the kind of tool-call a bluebook should compose.

## Shape (matches the Tools bluebook idiom)
`aggregates/video_editing/video_editing.bluebook`. A `Clip` aggregate `identified_by :ref`, attributes source / output / duration. Commands each compose an ffmpeg invocation :
- `FadeAudioOut` (st = duration - fade_seconds, d = fade_seconds)
- `FadeAudioIn`, `Trim` (in/out points), `SetVolume`, `Concat`, `ExtractAudio`, ...

"Domain composes the tool call ; the adapter runs it." Each command emits an event whose payload is the composed ffmpeg command ; a policy cascades into `Tools::ShellTool.Bash` (the :claude_tool adapter executes ffmpeg) and the outcome lands in `Cascade.RecordResult`. No new Rust adapter — reuses the existing ShellTool execution arm, same pattern as `RunSidequestOnDispatch`.

## Open design questions (decide API before implementing)
- Carry `duration` as state (probe via ffprobe on a `Load`/`Register` command) so `FadeAudioOut` computes `st` itself, vs. caller passes it.
- Do edits chain (output of one op feeds the next) via a `Timeline` / edit-list aggregate, or stay single-shot per `Clip`?
- Lock command names + signatures first (one rename pass, not three).

## Env note
ffmpeg was repaired this session : x265 version skew (Homebrew had upgraded x265 to .216 while ffmpeg 8.1 linked .215). `brew reinstall ffmpeg` relinked it ; `afade` verified available.

## Acceptance
- `VideoEditing::Clip.FadeAudioOut ref=pitch fade_seconds=20` produces a faded output file via the bus.
- `.behaviors` companion with `on:` / `tests:` lines ; validate + behaviors green.
- The YC Pitch audio fade gets finished through the domain, not the Resolve GUI.

Surfaced 2026-05-24 when the Resolve fade-handle fight prompted Chris : "can we do this in the terminal somehow? Can we make a video_editing.bluebook?" Companion to the Tools bluebook (framework/tools) — VideoEditing is a content-domain consumer of the ShellTool execution arm.

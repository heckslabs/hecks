# i711 — voice playback queue : ordered, non-overlapping (rebuild clean)

The non-blocking voice (commit d20f3508) plays each utterance in a detached
process, so rapid `Voice::Voice.Speak` dispatches OVERLAP. Goal (Chris): detect
that I'm mid-utterance and string the next one to the end — ordered,
non-overlapping playback, main thread still instant. "Don't cut yourself off."

## Design (from the parked WIP — rebuild clean from this)
- **Seq**: each Speak gets a monotonic dispatch-order number via read-modify-write
  of `<cache>/.seq`, guarded by atomic `mkdir <cache>/.seq.lock`.
  NOTE: `flock` does NOT exist on macOS — `mkdir` is the POSIX-atomic substitute.
- **Synth child (detached)**: curl ElevenLabs → `.part` → atomically `mv` into
  `queue/<NNNNNN>.mp3` (seq-numbered) → ensure a drain is running. Returns in ms
  (keep the non-blocking detach).
- **Singleton drain**: a small loop (singleton via atomic `mkdir .drain.lock`,
  trap-removed) plays the queue in strict seq order, one at a time ; waits up to a
  ~10s SKIP_TIMEOUT for the next expected seq, then steps past a failed synth ;
  resumes from a persisted `.played` watermark ; exits after ~10s idle.
- **Known bug in the dropped WIP** (avoid on rebuild): the drain loop referenced a
  removed `lowest()` helper and didn't write the `.played` watermark. Fix = an
  inline glob for "is a higher seq queued" + write `.played` on BOTH the play and
  skip paths.
- File: `rust/src/runtime/tts_dispatcher.rs`. Preserve WwS1 / eleven_v3 config ;
  no macOS `say` fallback.

## Verify
Fire 3 Speaks rapidly → play in order, no overlap, none cut off ; a failed synth
skips after the timeout ; main thread returns instant each time.

(The half-built WIP stash was dropped per Chris — rebuild clean from this card.)

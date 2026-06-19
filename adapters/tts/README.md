# tts — text-to-speech adapter (out-of-process)

The `tts` family lets a domain *speak*. It is the out-of-process replacement for the
in-runtime `rust/src/runtime/tts_dispatcher.rs` kernel hook — moving the impure
synthesis + playback out of the runtime, where the hexagon two-color rule says it
belongs (sync domain, async adapter, never a lock).

## Shape

- **`tts.family`** — the port. Verb `voiced_by`, signal `effect` **fire-and-forget**
  (no `produces`, no success/failure re-entry : speech is heard, not awaited).
  Config fields: `voice_id`, `model`, `speed`, `stability`, `similarity_boost`,
  `style`, `cache_dir`, `auto_play`.
- **`elevenlabs.adapter`** — the concrete adapter (provider identity). Declares
  `family "tts"` and the out-of-process `handler`.
- **`tts-handler.rb`** / **`tts-handler.rs`** — behaviour-parity handler programs
  (Ruby proven ; Rust sibling). The host runs whichever the deployment selects.

## Handler contract (mirrors `examples/adapter_host_demo/stripe-handler`)

- **stdin** : the trigger event payload as JSON (carries `text`).
- **env** : the adapter config the host folds in from `.world` — `VOICE_ID`
  (required), `MODEL`, `SPEED`, `STABILITY`, `SIMILARITY_BOOST`, `STYLE`,
  `CACHE_DIR`, `AUTO_PLAY`, `PROVIDER`.
- **exit** : always `0` on successful spawn. Fire-and-forget — no stdout verdict.
  Pre-flight failures exit `0` silently : there is **no macOS `say` fallback**,
  ever ("I'd rather you not speak than use the default").
- The ~11s synth+play runs in a **detached child** (own process group) so the
  handler returns immediately and a slow render never blocks the core.
- The API key is read from `~/.config/miette/elevenlabs.key` — never a bluebook value.

## Wiring (in the consuming domain, e.g. Voice)

```
# voice.hecksagon
Voice::Voice.voiced_by("ElevenLabs", on: "Speak")
```
```
# voice.world
Voice::Voice.voiced_by("ElevenLabs") do
  voice_id "WwS1lF7yiubZWoroH5D5"
  model    "eleven_turbo_v2_5"
  # speed / stability / similarity_boost / style / cache_dir / auto_play
end
```

Per the adapter-repo standard, these files are **copied into the consuming domain's
bluebook folder** when used. Only vetted examples are promoted into this repo.

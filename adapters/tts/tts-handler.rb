#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tts-handler (Ruby) — an out-of-process :tts adapter program for the generic
# adapter-host. The Ruby sibling of tts-handler.rs ; the two are behaviour-parity
# (same ElevenLabs call, same serial-playback lock, same silent-fail contract).
#
# This is the OUT-OF-PROCESS replacement for the in-runtime
# rust/src/runtime/tts_dispatcher.rs kernel hook. Moving it here is the point :
# the runtime parses bluebooks and emits the trigger event ; the IMPURE synthesis
# + playback lives in this separate program, so a slow/looping render can never
# block the synchronous domain core (the hexagon two-color rule).
#
# ADAPTER-HOST CONTRACT (mirrors examples/adapter_host_demo/stripe-handler) :
#   * STDIN  : the trigger event payload as JSON (carries `text` to render).
#   * ENV    : the adapter instance config the host folds in from .world, under
#              the canonical <FAMILY>_<FIELD> names the run_host config mapper
#              emits — TTS_VOICE_ID (required), TTS_MODEL, TTS_SPEED,
#              TTS_STABILITY, TTS_SIMILARITY_BOOST, TTS_STYLE, TTS_CACHE_DIR,
#              TTS_AUTO_PLAY. There is no provider knob : THIS handler IS the
#              elevenlabs handler (the provider is the adapter's identity, not
#              config).
#   * EXIT   : 0 always on successful SPAWN. `:tts` is fire-and-forget
#              (response_field :none) — there is no success/failure verdict and
#              no stdout verdict data. Pre-flight failures exit 0 too, silently :
#              Chris's rule is verbatim — "I'd rather you not speak than use the
#              default." There is NO macOS `say` fallback, ever.
#
# The ~11s of network synthesis + playback runs in a DETACHED child (its own
# process group) so this handler returns immediately, exactly as the kernel
# dispatcher did. The api key is read from ~/.config/miette/elevenlabs.key and
# passed to the child via env, never interpolated into the shell string.

require "json"

def debug(msg)
  warn "[tts-handler:rb] #{msg}" if ENV["HECKS_DEBUG_TTS"]
end

# Silent failure : log the reason, exit 0, never speak with a fallback voice.
def silent_exit(reason)
  debug "silent failure : #{reason}"
  exit 0
end

# ── text : from the event payload on stdin ──
raw = $stdin.read.to_s
payload = raw.empty? ? {} : (JSON.parse(raw) rescue {})
text = payload["text"].to_s.strip
silent_exit("no `text` in event payload") if text.empty?

home = ENV["HOME"].to_s

# ── provider config : voice_id required, the rest fall back to the WwS1 voice ──
voice_id = ENV["TTS_VOICE_ID"].to_s
silent_exit("no TTS_VOICE_ID (set voice_id on the :tts adapter / .world)") if voice_id.empty?
model   = (ENV["TTS_MODEL"]  || "eleven_turbo_v2_5")
speed   = (ENV["TTS_SPEED"]  || "1.2")
stability  = ENV["TTS_STABILITY"]
similarity = ENV["TTS_SIMILARITY_BOOST"]
style      = ENV["TTS_STYLE"]

# ── api key : silent fail when absent (no fallback voice) ──
key_path = File.join(home, ".config", "miette", "elevenlabs.key")
api_key = (File.read(key_path).strip rescue "")
silent_exit("cannot read #{key_path}") if api_key.empty?

# ── cache dir : resolve ~/ and create on demand ──
cache_raw = (ENV["TTS_CACHE_DIR"] || "~/.config/miette/audio")
cache_dir = cache_raw.sub(/\A~/, home)
require "fileutils"
FileUtils.mkdir_p(cache_dir)

ts = Time.now.utc.strftime("%Y%m%dT%H%M%S")
audio_path = File.join(cache_dir, "#{ts}.mp3")

def f(value, default)
  Float(value) rescue default
end

settings = +"\"speed\":#{f(speed, 1.2)}"
settings << ",\"stability\":#{f(stability, 0.5)}" if stability
settings << ",\"similarity_boost\":#{f(similarity, 0.75)}" if similarity
settings << ",\"style\":#{f(style, 0.0)}" if style

body = { "text" => text, "model_id" => model }.to_json
body = body.sub(/\}\z/, ",\"voice_settings\":{#{settings}}}")
url = "https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}"
auto_play = %w[true 1 yes].include?((ENV["TTS_AUTO_PLAY"] || "true").downcase)

lock_dir = File.join(cache_dir, ".tts_play.lock")
lock_pid = File.join(lock_dir, "pid")

# Serial playback (f16) : a mkdir lock so two close Speaks never overlap audibly.
# Stale-lock recovery : steal the lock if the PID inside is no longer alive.
play_step =
  if auto_play
    <<~'SH'.tr("\n", " ")
      while ! mkdir "$TTS_LOCK_DIR" 2>/dev/null; do
        if [ -f "$TTS_LOCK_PID" ]; then
          lp=$(cat "$TTS_LOCK_PID" 2>/dev/null);
          if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null; then rm -rf "$TTS_LOCK_DIR"; continue; fi;
        fi;
        sleep 0.1;
      done;
      echo $$ > "$TTS_LOCK_PID";
      trap 'rm -rf "$TTS_LOCK_DIR"' EXIT INT TERM HUP;
      /opt/homebrew/bin/mpg123 -q "$TTS_OUT"
    SH
  else
    ":"
  end

# curl writes the COMPLETE mp3 before playback ; a <=1024-byte file is the JSON
# error body ElevenLabs returns on failure — drop it and exit silently (no play).
script = <<~SH.tr("\n", " ") + play_step
  curl -s -X POST "$TTS_URL" -H "xi-api-key: $XI_API_KEY" -H 'Content-Type: application/json' -H 'Accept: audio/mpeg' -d "$TTS_BODY" --output "$TTS_OUT" || exit 0;
  sz=$(wc -c < "$TTS_OUT" 2>/dev/null || echo 0);
  if [ "$sz" -le 1024 ]; then rm -f "$TTS_OUT"; exit 0; fi;
SH

env = {
  "TTS_URL" => url, "XI_API_KEY" => api_key, "TTS_BODY" => body,
  "TTS_OUT" => audio_path, "TTS_LOCK_DIR" => lock_dir, "TTS_LOCK_PID" => lock_pid
}

# Detached child in its own process group : survives this handler's exit so the
# audio finishes even when the host reaps the handler immediately.
Process.spawn(env, "/bin/sh", "-c", script,
              pgroup: true, in: "/dev/null", out: "/dev/null", err: "/dev/null")
debug "spawned synth+play -> #{audio_path}"
exit 0

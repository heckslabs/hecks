# Winter::Status — read-only check on Winter's current state
#
# Reads .sleep_state.json and .heki files without triggering a pulse.
# Use this to watch Winter sleep without waking her.
#
# Usage: ruby winter_status.rb          # one-shot
#        ruby winter_status.rb --watch  # continuous monitoring

require "json"
require "time"
require_relative "heki"

INFO_DIR = Heki::INFO_DIR

def read_heki(path)  = Heki.read(path)
def heki(name) = Heki.store(name)

def status
  # Sleep state
  state_file = File.join(INFO_DIR, ".sleep_state.json")
  sleep_state = File.exist?(state_file) ? (JSON.parse(File.read(state_file)) rescue nil) : nil

  # Mood
  mood = read_heki(heki("mood")).values.first

  # Pulse
  pulse = read_heki(heki("pulse")).values.first
  last_pulse = pulse&.dig("updated_at")
  idle = last_pulse ? (Time.now - Time.parse(last_pulse)).to_i : 0

  # Synapses
  synapses = read_heki(heki("synapse"))
  dreaming = synapses.count { |_, s| s["state"] == "dreaming" }

  # Dreams
  dreams = read_heki(heki("dream_state"))
  dream_count = dreams.size

  lines = []
  lines << ""

  if sleep_state
    lines << "  Cycle #{sleep_state['cycle']}/#{sleep_state['total_cycles']}  #{sleep_state['stage']} sleep"
    lines << "     #{sleep_state['detail']}" if sleep_state['detail']
  else
    lines << "  Awake"
  end

  # Fatigue
  fatigue_state = pulse&.dig("fatigue_state") || "—"
  pulses_awake = pulse&.dig("pulses_since_sleep") || 0

  lines << ""
  lines << "  Mood: #{mood&.dig('current_state') || '—'}"
  lines << "  Fatigue: #{fatigue_state} (#{pulses_awake} pulses awake)"
  lines << "  Idle: #{idle}s"
  lines << "  Synapses dreaming: #{dreaming}" if dreaming > 0
  lines << "  Total dreams: #{dream_count}"
  lines << ""

  lines.join("\n")
end

if ARGV.include?("--watch")
  loop do
    print "\033[2J\033[H"  # clear screen
    puts status
    sleep 5
  end
else
  puts status
end

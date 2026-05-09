# statusline_snapshot_spec.rb
#
# [antibody-exempt: dream-study/test-gate/statusline_snapshot/statusline_snapshot_spec.rb —
#  Phase 0d test net for byte-exact statusline render. The spec is a test
#  harness (not a runtime script) and the contract being asserted IS the
#  bluebook : statusline.bluebook's render output, frozen as fixture bytes.]
#
# Contract : byte-identity for statusline render.
#
# This spec captures the exact bytes the statusline renderer emits for every
# (mode, state) tuple Miette can be in : five sleep stages (light, rem, deep,
# final_light, lucid_rem), eight representative awake mood/fatigue combos, and
# the minimal-mode coherence-violation shape. Each fixture is :
#
#   - heki seeds (mood, heartbeat, consciousness, tick, musing_mint,
#     claude_assist, lucid_dream where relevant)
#   - the expected rendered line, with {{MOON}} / {{HEART}} / {{BULB}} / {{INBOX}}
#     placeholders for the wall-clock-driven glyphs and the public inbox count
#     (those depend on the host clock and the live repo's inbox.heki, neither
#     of which is part of the rendering contract being asserted)
#
# The spec seeds an isolated tmp HECKS_INFO, runs `hecks-life statusline`,
# normalizes the wall-clock-driven glyphs to the same placeholders, and
# asserts byte equality.
#
# Future PRs (statusline-as-query, the Phase 9 IR-walker conversion) must
# produce byte-identical normalized output OR explicitly update the affected
# fixture file in the same PR — that delta becomes a code-review touchpoint.
#
# Usage :
#   rspec statusline_snapshot_spec.rb
#
# Optional env :
#   HECKS_LIFE  override path to the hecks-life binary

require "rspec"
require "yaml"
require "tmpdir"
require "fileutils"

HERE = File.expand_path(__dir__)
FIXTURE_DIR = File.join(HERE, "fixtures")

# Locate the hecks-life binary. Honors $HECKS_LIFE ; otherwise picks the
# first existing release/debug build under the hecks repo.
def hecks_life_path
  return ENV["HECKS_LIFE"] if ENV["HECKS_LIFE"] && File.executable?(ENV["HECKS_LIFE"])
  candidates = [
    "/Users/christopheryoung/Projects/hecks/rust/target/release/hecks-life",
    "/Users/christopheryoung/Projects/hecks/rust/target/debug/hecks-life",
  ]
  candidates.find { |p| File.executable?(p) } or
    raise "hecks-life binary not found ; set HECKS_LIFE"
end

# Format a value for the `hecks-life heki upsert` CLI : the CLI accepts raw
# key=value pairs (the key=value parser splits on the first '='). Because we
# spawn the binary via IO.popen with an array-form argv, no shell quoting is
# needed even when values contain spaces or apostrophes ; we pass the literal
# bytes through.
def format_arg(key, val)
  "#{key}=#{val}"
end

# Seed one heki file from a hash of fields. Uses --reason to satisfy the
# out-of-band write contract.
def seed_heki(info_dir, name, fields)
  args = fields.map { |k, v| format_arg(k.to_s, v) }
  cmd = [hecks_life_path, "heki", "upsert",
         File.join(info_dir, "#{name}.heki"),
         "--reason",
         "test setup : statusline_snapshot fixture seed for #{name}",
         *args]
  out = IO.popen(cmd, err: [:child, :out]) { |io| io.read }
  raise "seed_heki failed for #{name} : #{out}" unless $?.success?
end

# Run the statusline renderer. Pipes empty stdin (the harness drains it).
# Captures stdout. Returns the line without its trailing newline.
def render_statusline(info_dir)
  out = IO.popen([{ "HECKS_INFO" => info_dir }, hecks_life_path, "statusline"],
                 "r+") do |io|
    io.close_write
    io.read
  end
  raise "statusline failed (exit=#{$?.exitstatus}) : #{out}" unless $?.success?
  out.chomp("\n")
end

# Replace wall-clock-driven glyphs and the public inbox count with stable
# placeholders so the snapshot is comparable across host clocks and live
# repo state. The contract being asserted is "render is a deterministic
# function of seeded heki state PLUS time" — time is normalized out.
#
# Only TWO time-driven glyphs ever appear in the rendered line :
#   - moon (sleep mode) — 8 phases drift on (secs % 8)
#   - heart (awake mode) — 2 phases flip on (nanos / 333ms % 2)
# The third animated glyph (bulb : 💡/🌟/✨/💫) appears only when
# /tmp/miette_minting exists AND awake mode AND sleep_summary is non-empty —
# none of our fixtures populate that combination, so bulb never appears.
# Other glyphs that look like animation candidates (✨ before lucid narrative,
# 💫 inside the groggy mood ZWJ sequence) are content, not animation, and
# must NOT be normalized.
MOON_GLYPHS  = %w[🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘].freeze
HEART_GLYPHS = ["🖤", "❤️"].freeze
def normalize(line)
  out = line.dup
  MOON_GLYPHS.each  { |g| out.gsub!(g, "{{MOON}}") }
  HEART_GLYPHS.each { |g| out.gsub!(g, "{{HEART}}") }
  # Public inbox count : "✉️ <n>" → "✉️ {{INBOX}}". The renderer hides this
  # entire row when count == 0, so the placeholder won't appear in either
  # rendered or expected line in that case (gsub is a no-op).
  out.gsub!(/✉️ \d+/, "✉️ {{INBOX}}")
  out
end

def load_fixture(path)
  YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
end

# rspec-time : one example per fixture file.
RSpec.describe "statusline byte-exact snapshots" do
  fixtures = Dir.glob(File.join(FIXTURE_DIR, "*.fixture")).sort
  raise "no fixtures found under #{FIXTURE_DIR}" if fixtures.empty?

  fixtures.each do |fixture_path|
    name = File.basename(fixture_path, ".fixture")
    it "renders #{name} byte-identical to its fixture" do
      data = load_fixture(fixture_path)
      seeds    = data.fetch("heki_seeds")
      expected = data.fetch("expected_render").chomp("\n")

      Dir.mktmpdir("statusline_snapshot.") do |info|
        seeds.each { |aggregate, fields| seed_heki(info, aggregate, fields) }
        # Tick baseline : status_coherence.sh invariant 4 needs <ts cycle>
        # written so the monotonicity check has a baseline. Fresh-now baseline
        # makes the delta zero (always within tolerance).
        if (tick = seeds["tick"])
          File.write(File.join(info, ".tick_baseline"),
                     "#{Time.now.to_i} #{tick['cycle'] || tick[:cycle]}\n")
        end
        rendered = render_statusline(info)
        expect(normalize(rendered)).to eq(expected)
      end
    end
  end
end

# Hecks::Parity::WorldParityTest
#
# Runs every `.world` file in-tree through both the Ruby DSL builder and
# the Rust hecks-life parser, normalizes both outputs to the canonical
# JSON shape (see canonical_ir.rb :: dump_world / main.rs ::
# dump_world_json), and diffs.
#
# Status legend:
#   ✓  parity
#   ✗  unexpected drift — exit 1 (the pre-commit hook blocks)
#   ⚠  expected drift (listed in world_known_drift.txt) — does not block
#   ⚑  fixture in known_drift.txt that now PASSES — celebrate, then remove
#
# Run: ruby -Ilib spec/parity/world_parity_test.rb
#
require "json"
require "open3"
require "hecks"
require_relative "canonical_ir"

HECKS_LIFE = File.expand_path("../../hecks_life/target/release/hecks-life", __dir__)
REPO_ROOT  = File.expand_path("../..", __dir__)

# Cover every `.world` shipped in-tree except node_modules / vendor / git
# trees. Roots are named explicitly so a misplaced .world file at the
# repo root doesn't silently join the parity suite.
WORLD_FILES = (
  Dir[File.join(REPO_ROOT, "hecks_conception", "**", "*.world")] +
  Dir[File.join(REPO_ROOT, "lib", "**", "*.world")] +
  Dir[File.join(REPO_ROOT, "examples", "**", "*.world")]
).sort.uniq

KNOWN_DRIFT_FILE = File.expand_path("world_known_drift.txt", __dir__)

abort "hecks-life not built — run: (cd hecks_life && cargo build --release)" unless File.executable?(HECKS_LIFE)

def load_known_drift
  return {} unless File.exist?(KNOWN_DRIFT_FILE)
  File.readlines(KNOWN_DRIFT_FILE).each_with_object({}) do |line, acc|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    path, comment = line.split("#", 2).map(&:strip)
    acc[path] = comment.to_s
  end
end

KNOWN_DRIFT = load_known_drift

def ruby_dump(path)
  # The .world file calls Hecks.world "..." do ... end. Clear any prior
  # last_world so a failed load can't pollute the next file.
  Hecks.last_world = nil if Hecks.respond_to?(:last_world=)
  Kernel.load(path)
  Hecks::Parity::CanonicalIR.dump_world(Hecks.last_world)
end

def rust_dump(path)
  out, err, status = Open3.capture3(HECKS_LIFE, "dump-world", path)
  raise "rust dump-world failed for #{path}: #{err}" unless status.success?
  JSON.parse(out)
end

def deep_sort(o)
  case o
  when Hash  then o.sort.map { |k, v| [k, deep_sort(v)] }.to_h
  when Array then o.map { |e| deep_sort(e) }
  else o
  end
end

def diff_lines(a, b)
  a_str = JSON.pretty_generate(deep_sort(a))
  b_str = JSON.pretty_generate(deep_sort(b))
  return [] if a_str == b_str
  a_lines = a_str.lines.map(&:chomp)
  b_lines = b_str.lines.map(&:chomp)
  result = []
  [a_lines.size, b_lines.size].max.times do |i|
    al, bl = a_lines[i], b_lines[i]
    next if al == bl
    result << "  L#{i + 1}  Ruby: #{al.inspect}"
    result << "        Rust: #{bl.inspect}"
  end
  result
end

def run_one(path)
  begin
    ruby_ir = ruby_dump(path)
    rust_ir = rust_dump(path)
  rescue ScriptError, StandardError => e
    return [:error, "error: #{e.message.lines.first&.chomp}"]
  end
  return [:pass, nil] if ruby_ir == rust_ir
  [:fail, diff_lines(ruby_ir, rust_ir).first(40).join("\n")]
end

puts "=== .world parity (#{WORLD_FILES.size} files) ==="
abort "no .world files found under hecks_conception/, lib/, examples/" if WORLD_FILES.empty?

blocking = 0
expected = 0
unexpected_passes = []

WORLD_FILES.each do |p|
  rel = p.sub(REPO_ROOT + "/", "")
  known = KNOWN_DRIFT.key?(rel)
  status, body = run_one(p)
  case status
  when :pass
    if known
      puts "⚑ #{rel} — listed in known_drift.txt but PASSES; remove that line"
      unexpected_passes << rel
    else
      puts "✓ #{rel}"
    end
  when :fail, :error
    if known
      puts "⚠ #{rel}  (known: #{KNOWN_DRIFT[rel]})"
      expected += 1
    else
      puts "✗ #{rel} — #{status == :error ? body : 'drift'}"
      puts body if status == :fail
      blocking += 1
    end
  end
end

total  = WORLD_FILES.size
passed = total - blocking - expected - unexpected_passes.size
puts ""
puts "#{passed}/#{total} match"
puts "#{expected} known-drift (allowed)" if expected > 0
unless unexpected_passes.empty?
  puts ""
  puts "⚑ #{unexpected_passes.size} fixture(s) in known_drift.txt now pass — please remove:"
  unexpected_passes.each { |f| puts "    #{f}" }
end

exit(blocking == 0 ? 0 : 1)

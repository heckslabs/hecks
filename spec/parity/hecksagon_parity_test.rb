# Hecks::Parity::HecksagonParityTest
#
# Runs every `.hecksagon` file in-tree through both the Ruby DSL
# builder and the Rust hecks-life parser, normalizes both outputs to
# the canonical JSON shape (see canonical_ir.rb :: dump_hecksagon /
# main.rs :: dump_hecksagon_json), and diffs.
#
# Canonical shape is the subset both parsers model: name, persistence,
# subscriptions, io_adapters, shell_adapters, gates. Ruby-only fields
# (capabilities, concerns, annotations, context_map, ...) go in
# hecksagon_known_drift.txt until the Rust IR grows them.
#
# Status legend:
#   ✓  parity
#   ✗  unexpected drift — exit 1 (the pre-commit hook blocks)
#   ⚠  expected drift (listed in hecksagon_known_drift.txt) — does not block
#   ⚑  fixture in known_drift.txt that now PASSES — celebrate, then remove
#
# Run: ruby -Ilib spec/parity/hecksagon_parity_test.rb
#
require "json"
require "open3"
require "hecks"
require_relative "canonical_ir"

HECKS_LIFE = File.expand_path("../../hecks_life/target/release/hecks-life", __dir__)
REPO_ROOT  = File.expand_path("../..", __dir__)

HECKSAGON_FILES = (
  Dir[File.join(REPO_ROOT, "hecks_conception", "**", "*.hecksagon")] +
  Dir[File.join(REPO_ROOT, "lib", "**", "*.hecksagon")] +
  Dir[File.join(REPO_ROOT, "examples", "**", "*.hecksagon")]
).sort.uniq

KNOWN_DRIFT_FILE = File.expand_path("hecksagon_known_drift.txt", __dir__)

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
  Hecks.last_hecksagon = nil if Hecks.respond_to?(:last_hecksagon=)
  Kernel.load(path)
  Hecks::Parity::CanonicalIR.dump_hecksagon(Hecks.last_hecksagon)
end

def rust_dump(path)
  out, err, status = Open3.capture3(HECKS_LIFE, "dump-hecksagon", path)
  raise "rust dump-hecksagon failed for #{path}: #{err}" unless status.success?
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

puts "=== .hecksagon parity (#{HECKSAGON_FILES.size} files) ==="
abort "no .hecksagon files found" if HECKSAGON_FILES.empty?

blocking = 0
expected = 0
unexpected_passes = []

HECKSAGON_FILES.each do |p|
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

total  = HECKSAGON_FILES.size
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

# Hecks::Parity::ParityTest
#
# Runs every fixture in spec/parity/bluebooks/ and every real bluebook in
# hecks_conception/aggregates/ through both the Ruby DSL parser and the
# Rust hecks-life parser, normalizes both outputs to the canonical JSON
# shape (see canonical_ir.rb and dump.rs), and diffs.
#
# Status legend:
#   ✓  parity
#   ✗  unexpected drift — exit 1 (the pre-commit hook blocks)
#   ⚠  expected drift (listed in known_drift.txt) — does not block
#   ⚑  fixture in known_drift.txt that now PASSES — celebrate, then remove
#
# Run: ruby -Ilib spec/parity/parity_test.rb
#
require "json"
require "open3"
require "hecks"
require_relative "canonical_ir"

HECKS_LIFE = File.expand_path("../../hecks_life/target/release/hecks-life", __dir__)
SYNTHETIC  = Dir[File.expand_path("bluebooks/*.bluebook", __dir__)].sort
REAL       = Dir[File.expand_path("../../hecks_conception/aggregates/*.bluebook", __dir__)].sort
CAPS       = Dir[File.expand_path("../../hecks_conception/capabilities/**/*.bluebook", __dir__)].sort
CATALOG    = Dir[File.expand_path("../../hecks_conception/catalog/**/*.bluebook", __dir__)].sort
MISC       = (Dir[File.expand_path("../../hecks_conception/family/**/*.bluebook", __dir__)] +
              Dir[File.expand_path("../../hecks_conception/applications/**/*.bluebook", __dir__)] +
              Dir[File.expand_path("../../hecks_conception/actions/**/*.bluebook", __dir__)] +
              Dir[File.expand_path("../../hecks_conception/chris/**/*.bluebook", __dir__)]).sort
KNOWN_DRIFT_FILE = File.expand_path("known_drift.txt", __dir__)
REPO_ROOT  = File.expand_path("../..", __dir__)

abort "hecks-life not built — run: (cd hecks_life && cargo build --release)" unless File.executable?(HECKS_LIFE)
abort "no fixtures in spec/parity/bluebooks/" if SYNTHETIC.empty?

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
  Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
    Kernel.load(path)
  end
  Hecks::Parity::CanonicalIR.dump(Hecks.last_domain)
end

def rust_dump(path)
  out, err, status = Open3.capture3(HECKS_LIFE, "dump", path)
  raise "rust dump failed for #{path}: #{err}" unless status.success?
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
  max = [a_lines.size, b_lines.size].max
  max.times do |i|
    al, bl = a_lines[i], b_lines[i]
    next if al == bl
    result << "  L#{i+1}  Ruby: #{al.inspect}"
    result << "        Rust: #{bl.inspect}"
  end
  result
end

def run_one(path, max_diff_lines: 40)
  begin
    ruby_ir = ruby_dump(path)
    rust_ir = rust_dump(path)
  rescue ScriptError, StandardError => e
    return [:error, "error before diff: #{e.message.lines.first&.chomp}"]
  end

  return [:pass, nil] if ruby_ir == rust_ir
  diffs = diff_lines(ruby_ir, rust_ir)
  shown = diffs.first(max_diff_lines)
  shown << "  …(#{diffs.size - max_diff_lines} more lines)" if diffs.size > max_diff_lines
  [:fail, shown.join("\n")]
end

def section(title, paths, max_diff_lines:)
  return [0, 0, 0, []] if paths.empty?
  puts "\n=== #{title} (#{paths.size}) ==="
  blocking = 0
  expected = 0
  unexpected_passes = []
  paths.each do |p|
    rel = p.sub(REPO_ROOT + "/", "")
    known = KNOWN_DRIFT.key?(rel)
    status, body = run_one(p, max_diff_lines: max_diff_lines)
    case status
    when :pass
      if known
        puts "⚑ #{rel} — listed in known_drift.txt but PASSES; remove that line"
        unexpected_passes << rel
      else
        puts "✓ #{rel}"
      end
    when :fail, :error
      label = (status == :error ? body : "drift")
      if known
        puts "⚠ #{rel}  (known: #{KNOWN_DRIFT[rel]})"
        expected += 1
      else
        puts "✗ #{rel} — #{label}"
        puts body if status == :fail
        blocking += 1
      end
    end
  end
  [paths.size, blocking, expected, unexpected_passes]
end

s_total, s_block, s_expected, s_unx = section("Synthetic fixtures", SYNTHETIC, max_diff_lines: 40)
r_total, r_block, r_expected, r_unx = section("Real bluebooks (aggregates/)", REAL, max_diff_lines: 8)
c_total, c_block, c_expected, c_unx = section("Capability bluebooks (capabilities/)", CAPS, max_diff_lines: 8)
k_total, k_block, k_expected, k_unx = section("Catalog bluebooks (catalog/)", CATALOG, max_diff_lines: 8)
m_total, m_block, m_expected, m_unx = section("Misc bluebooks (family/applications/actions/chris)", MISC, max_diff_lines: 8)

total       = s_total + r_total + c_total + k_total + m_total
blocking    = s_block + r_block + c_block + k_block + m_block
expected    = s_expected + r_expected + c_expected + k_expected + m_expected
unx_passes  = s_unx + r_unx + c_unx + k_unx + m_unx
passed      = total - blocking - expected - unx_passes.size

puts ""
puts "#{passed}/#{total} match"
puts "  synthetic #{s_total - s_block - s_expected}/#{s_total}"
puts "  real (aggregates) #{r_total - r_block - r_expected}/#{r_total}"
puts "  capabilities #{c_total - c_block - c_expected}/#{c_total}"
puts "  catalog #{k_total - k_block - k_expected}/#{k_total}"
puts "  misc #{m_total - m_block - m_expected}/#{m_total}"
puts "#{expected} known-drift (allowed)" if expected > 0
unless unx_passes.empty?
  puts ""
  puts "⚑ #{unx_passes.size} fixture(s) in known_drift.txt now pass — please remove:"
  unx_passes.each { |f| puts "    #{f}" }
end

# Exit 1 only on UNEXPECTED drift. Known drift and unexpected-passes don't block.
exit(blocking == 0 ? 0 : 1)

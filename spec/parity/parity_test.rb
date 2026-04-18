# Hecks::Parity::ParityTest
#
# Runs every fixture in spec/parity/bluebooks/ through both the Ruby DSL
# parser and the Rust hecks-life parser, normalizes both outputs to the
# canonical JSON shape, and diffs. Any structural disagreement is drift.
#
# Run: ruby -Ilib spec/parity/parity_test.rb
#
# Exit 0 if every fixture matches, exit 1 with a per-fixture diff otherwise.
# Add new fixtures by dropping a .bluebook into spec/parity/bluebooks/.
#
require "json"
require "open3"
require "hecks"
require_relative "canonical_ir"

HECKS_LIFE = File.expand_path("../../hecks_life/target/release/hecks-life", __dir__)
SYNTHETIC  = Dir[File.expand_path("bluebooks/*.bluebook", __dir__)].sort
REAL       = Dir[File.expand_path("../../hecks_conception/aggregates/*.bluebook", __dir__)].sort

abort "hecks-life not built — run: (cd hecks_life && cargo build --release)" unless File.executable?(HECKS_LIFE)
abort "no fixtures in spec/parity/bluebooks/" if SYNTHETIC.empty?

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
  rescue => e
    return [:error, "error before diff: #{e.message.lines.first&.chomp}"]
  end

  return [:pass, nil] if ruby_ir == rust_ir
  diffs = diff_lines(ruby_ir, rust_ir)
  shown = diffs.first(max_diff_lines)
  shown << "  …(#{diffs.size - max_diff_lines} more lines)" if diffs.size > max_diff_lines
  [:fail, shown.join("\n")]
end

def section(title, paths, max_diff_lines:)
  return [0, 0] if paths.empty?
  puts "\n=== #{title} (#{paths.size}) ==="
  failed = 0
  paths.each do |p|
    name = p.sub(File.expand_path("../..", __dir__) + "/", "")
    status, body = run_one(p, max_diff_lines: max_diff_lines)
    case status
    when :pass  then puts "✓ #{name}"
    when :fail  then puts "✗ #{name}"; puts body; failed += 1
    when :error then puts "✗ #{name} — #{body}"; failed += 1
    end
  end
  [paths.size, failed]
end

s_total, s_failed = section("Synthetic fixtures", SYNTHETIC, max_diff_lines: 40)
r_total, r_failed = section("Real bluebooks (aggregates/)", REAL, max_diff_lines: 8)

total  = s_total + r_total
failed = s_failed + r_failed
passed = total - failed

puts "\n#{passed}/#{total} match  (synthetic #{s_total - s_failed}/#{s_total}, real #{r_total - r_failed}/#{r_total})"
exit(failed == 0 ? 0 : 1)

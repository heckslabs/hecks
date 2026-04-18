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
FIXTURES   = Dir[File.expand_path("bluebooks/*.bluebook", __dir__)].sort

abort "hecks-life not built — run: (cd hecks_life && cargo build --release)" unless File.executable?(HECKS_LIFE)
abort "no fixtures in spec/parity/bluebooks/" if FIXTURES.empty?

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

failed = 0
FIXTURES.each do |fixture|
  name = File.basename(fixture)
  begin
    ruby_ir = ruby_dump(fixture)
    rust_ir = rust_dump(fixture)
  rescue => e
    puts "✗ #{name} — error before diff: #{e.message}"
    failed += 1
    next
  end

  if ruby_ir == rust_ir
    puts "✓ #{name}"
  else
    puts "✗ #{name}"
    diffs = diff_lines(ruby_ir, rust_ir)
    diffs.first(40).each { |l| puts l }
    puts "  …(#{diffs.size - 40} more lines)" if diffs.size > 40
    failed += 1
  end
end

if failed == 0
  puts "\n#{FIXTURES.size}/#{FIXTURES.size} fixtures match"
  exit 0
else
  puts "\n#{failed} of #{FIXTURES.size} fixtures drifted"
  exit 1
end

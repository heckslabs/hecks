# Hecks::Parity::BehaviorsParityTest
#
# Runs the same `_behavioral_tests.bluebook` files through both the
# Rust runner (`hecks-life behaviors`) and the Ruby runner
# (`bin/hecks-behaviors`), then diffs the per-test pass/fail/error
# verdicts. Drift between runners is a hard contract failure.
#
# Status legend:
#   ✓  identical verdicts
#   ✗  divergence — exit 1 (the pre-commit hook should block this)
#
# Run: ruby -Ilib spec/parity/behaviors_parity_test.rb
#
require "open3"

HECKS_LIFE   = File.expand_path("../../hecks_life/target/release/hecks-life", __dir__)
RUBY_RUNNER  = File.expand_path("../../bin/hecks-behaviors", __dir__)
KNOWN_DRIFT  = File.expand_path("behaviors_known_drift.txt", __dir__)

# A small sample by default so the suite runs in seconds. Pass a glob
# via ARGV[0] (e.g. "hecks_conception/nursery/**/*.behaviors") to widen.
DEFAULT_SAMPLE = %w[
  hecks_conception/catalog/pizzas.behaviors
  hecks_conception/family/conventions.behaviors
  hecks_conception/family/king_mango.behaviors
].select { |p| File.exist?(File.expand_path("../../#{p}", __dir__)) }

abort "hecks-life not built" unless File.executable?(HECKS_LIFE)
abort "ruby runner missing"  unless File.executable?(RUBY_RUNNER)

# Parse "X passed, Y failed, Z errored" from a runner's tail output.
def parse_summary(out)
  if (m = out.match(/(\d+) passed,\s+(\d+) failed,\s+(\d+) errored/))
    return { pass: m[1].to_i, fail: m[2].to_i, error: m[3].to_i }
  end
  { pass: 0, fail: 0, error: 0 }
end

# Per-test verdict map: "test description" → :pass / :fail / :error.
def parse_verdicts(out)
  verdicts = {}
  out.each_line do |line|
    case line
    when /\A✓ (.+)\Z/ then verdicts[$1.strip] = :pass
    when /\A✗ (.+)\Z/ then verdicts[$1.strip] = :fail
    when /\A⚠ (.+)\Z/ then verdicts[$1.strip] = :error
    end
  end
  verdicts
end

def load_known_drift
  return [] unless File.exist?(KNOWN_DRIFT)
  File.readlines(KNOWN_DRIFT).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
end

target_files = ARGV.empty? ? DEFAULT_SAMPLE : Dir.glob(ARGV[0])
abort "no behavioral test files matched" if target_files.empty?

drift = load_known_drift
divergent = 0
agreed    = 0

target_files.sort.each do |tf|
  ruby_out, _ = Open3.capture2e(RUBY_RUNNER, tf)
  rust_out, _ = Open3.capture2e(HECKS_LIFE, "behaviors", tf)

  ruby_sum = parse_summary(ruby_out)
  rust_sum = parse_summary(rust_out)

  ruby_v = parse_verdicts(ruby_out)
  rust_v = parse_verdicts(rust_out)

  same_summary = ruby_sum == rust_sum
  same_verdicts = ruby_v == rust_v
  drift_listed  = drift.include?(tf)

  if same_summary && same_verdicts
    puts "✓ #{tf}  (#{rust_sum[:pass]}/#{rust_v.size})"
    agreed += 1
  elsif drift_listed
    puts "⚠ #{tf}  drift (known)"
  else
    puts "✗ #{tf}"
    puts "    rust: #{rust_sum.inspect}"
    puts "    ruby: #{ruby_sum.inspect}"
    only_in_ruby = ruby_v.keys - rust_v.keys
    only_in_rust = rust_v.keys - ruby_v.keys
    differ_keys  = (ruby_v.keys & rust_v.keys).select { |k| ruby_v[k] != rust_v[k] }
    puts "    only in ruby: #{only_in_ruby.inspect}" unless only_in_ruby.empty?
    puts "    only in rust: #{only_in_rust.inspect}" unless only_in_rust.empty?
    differ_keys.each { |k| puts "    diff: #{k.inspect}  rust=#{rust_v[k]}  ruby=#{ruby_v[k]}" }
    divergent += 1
  end
end

puts
puts "#{agreed}/#{target_files.size} parity"
exit(divergent.zero? ? 0 : 1)

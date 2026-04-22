# Hecks::Parity::Fuzz::FuzzTest
#
# Purpose: driver for the i30 differential runtime fuzzer.
# Iterates seeds, dispatches each generated program against the
# Ruby and Rust runtimes, compares heki state via the canonicalizer,
# and writes minimal failing cases to spec/parity/fuzz/failures/.
#
# CLI:
#   ruby -Ilib spec/parity/fuzz/fuzz_test.rb [options]
#
# Options:
#   --seed N             Run only seed N (great for reproducing)
#   --count N            Run N seeds starting at 1 (default: 200)
#   --budget-seconds S   Stop iterating after S wall-clock seconds
#                        (default: 80 — matches 200 × 0.4s local)
#   --start N            First seed (default: 1 — seed 1 is the
#                        hand-tuned cascade regression gate)
#   --verbose            Print per-seed pass/fail line
#
# Exit codes:
#   0  all seeds agreed OR only-known-drift divergences
#   1  unlisted divergence seen — block pre-commit isn't this job's
#      concern (fuzz is opt-in), but CI nightly fails fast
#
# Known-drift format: spec/parity/fuzz/known_drift_fuzz.txt keyed
# by seed (see docstring at top of that file). Blank + `#` lines
# ignored.
#
# [antibody-exempt: differential fuzzer per i30 plan — retires when
# fuzzer ports to bluebook-dispatched form via hecks-life run]

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "fileutils"
require "json"
require "optparse"

require_relative "generator"
require_relative "runner"
require_relative "comparator"

HECKS_LIFE = File.expand_path("../../../hecks_life/target/release/hecks-life", __dir__)
FAILURES_DIR = File.expand_path("failures", __dir__)
KNOWN_DRIFT = File.expand_path("known_drift_fuzz.txt", __dir__)

unless File.executable?(HECKS_LIFE)
  abort "hecks-life not built — run: (cd hecks_life && cargo build --release)"
end

options = { seed: nil, count: 200, budget_seconds: 80, start: 1, verbose: false }
OptionParser.new do |o|
  o.on("--seed N", Integer)           { |n| options[:seed]   = n }
  o.on("--count N", Integer)          { |n| options[:count]  = n }
  o.on("--budget-seconds S", Integer) { |s| options[:budget_seconds] = s }
  o.on("--start N", Integer)          { |n| options[:start]  = n }
  o.on("--verbose")                   { options[:verbose] = true }
end.parse!

def load_known_drift
  return {} unless File.exist?(KNOWN_DRIFT)
  File.readlines(KNOWN_DRIFT).each_with_object({}) do |line, acc|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    if (m = line.match(/\Aseed=(\d+)(?:\s+(.+))?\z/))
      acc[m[1].to_i] = (m[2] || "").strip
    end
  end
end

def seeds_to_run(options)
  if options[:seed]
    [options[:seed]]
  else
    start = options[:start]
    count = options[:count]
    (start...(start + count)).to_a
  end
end

def load_domain_for(program)
  Hecks.instance_variable_set(:@last_domain, nil)
  Tempfile.open(["fuzz-parse", ".bluebook"]) do |f|
    f.write(program.bluebook)
    f.flush
    Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
      Kernel.load(f.path)
    end
  end
  Hecks.last_domain
end

def write_failure(program, verdict, result)
  dir = File.join(FAILURES_DIR, program.seed.to_s)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "#{program.name}.bluebook"), program.bluebook)
  File.write(File.join(dir, "program.json"),
             JSON.pretty_generate(seed: program.seed, commands: program.commands))
  File.write(File.join(dir, "reason.txt"), verdict.reason)
  File.write(File.join(dir, "diff.txt"),
             Hecks::Parity::Fuzz::Comparator.pretty_diff(verdict.ruby_canonical,
                                                         verdict.rust_canonical))
  # Copy the actual heki stores for forensic inspection.
  FileUtils.cp_r(result.ruby_dir, File.join(dir, "ruby_heki"))
  FileUtils.cp_r(result.rust_dir, File.join(dir, "rust_heki"))
end

require "tempfile"
require "hecks"

drift = load_known_drift
seeds = seeds_to_run(options)
start_time = Time.now
budget = options[:budget_seconds].to_f
ran = 0
agreed = 0
divergent = 0
expected_drift = 0
divergent_seeds = []

seeds.each do |seed|
  break if !options[:seed] && (Time.now - start_time) > budget
  ran += 1
  program = Hecks::Parity::Fuzz::Generator.generate(seed)
  domain = load_domain_for(program)
  result  = Hecks::Parity::Fuzz::Runner.run(program, hecks_life_bin: HECKS_LIFE)
  verdict = Hecks::Parity::Fuzz::Comparator.compare(result, domain)

  if verdict.status == :agree
    agreed += 1
    puts "seed=#{seed} ✓ #{verdict.reason}" if options[:verbose]
    FileUtils.rm_rf(result.root)
  elsif drift.key?(seed)
    expected_drift += 1
    puts "seed=#{seed} ⚠ listed drift: #{drift[seed]}" if options[:verbose]
    FileUtils.rm_rf(result.root)
  else
    divergent += 1
    divergent_seeds << seed
    puts "seed=#{seed} ✗ #{verdict.reason[0, 100]}"
    write_failure(program, verdict, result)
    FileUtils.rm_rf(result.root)
  end
end

elapsed = Time.now - start_time
puts "\nFuzz summary:"
puts "  ran: #{ran}   agreed: #{agreed}   expected-drift: #{expected_drift}   divergent: #{divergent}"
puts "  elapsed: #{elapsed.round(1)}s"
if divergent > 0
  puts "  divergent seeds: #{divergent_seeds.join(', ')}"
  puts "  failures dir: #{FAILURES_DIR}"
end

exit(divergent > 0 ? 1 : 0)

require "spec_helper"
require "open3"
require "tmpdir"

# The startup budget of docs/cli-measures.md: a warm bare `hecks` answer, measured in a fresh
# Ruby process, must stay under three times the baseline recorded there. The baseline is a ratio
# to the floor of the machine that runs the check, a fresh process that only sets up the bundle,
# so a slower machine (a shared CI runner is about four times slower) moves both together.
RSpec.describe "warm bare hecks startup budget" do
  BASELINE_RATIO = 2.8
  CEILING_RATIO = 3 * BASELINE_RATIO
  RUNS = 5

  FLOOR = 'require "bundler/setup"'.freeze

  PROGRAM = <<~RUBY.freeze
    require "bundler/setup"
    require "hecks"
    described = Hecks.describe(File.expand_path("lib/hecks/hecks"))
    Hecks::Adapters::Driving::CliRunner.usage(runtime: described, argv: [], program: "hecks")
  RUBY

  def root
    File.expand_path("..", __dir__)
  end

  def spawn_once(cache, program)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, err, status = Open3.capture3({ "HECKS_CACHE_DIR" => cache }, "ruby", "-I", "lib", "-e", program, chdir: root)
    raise "launcher failed: #{err}" unless status.success?

    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def warm_median(cache, program)
    spawn_once(cache, program)
    times = Array.new(RUNS) { spawn_once(cache, program) }.sort
    times[RUNS / 2]
  end

  def verdict(hecks, floor)
    "warm median #{hecks.round(2)}s is #{(hecks / floor).round(2)} times the " \
      "#{floor.round(2)}s bundle floor; the ceiling is #{CEILING_RATIO.round(2)} times"
  end

  it "answers a warm bare hecks under the ceiling" do
    Dir.mktmpdir do |cache|
      hecks = warm_median(cache, PROGRAM)
      floor = warm_median(cache, FLOOR)
      expect(hecks / floor).to be < CEILING_RATIO, verdict(hecks, floor)
    end
  end
end

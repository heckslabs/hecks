require "spec_helper"
require "open3"
require "tmpdir"

# The startup budget of docs/cli-measures.md: a warm bare `hecks` answer, measured in a fresh
# Ruby process, must stay under three times the baseline recorded there.
RSpec.describe "warm bare hecks startup budget" do
  BASELINE_SECONDS = 0.49
  CEILING_SECONDS = 3 * BASELINE_SECONDS
  RUNS = 5

  PROGRAM = <<~RUBY.freeze
    require "bundler/setup"
    require "hecks"
    described = Hecks.describe(File.expand_path("lib/hecks/hecks"))
    Hecks::Adapters::Driving::CliRunner.usage(runtime: described, argv: [], program: "hecks")
  RUBY

  def root
    File.expand_path("..", __dir__)
  end

  def spawn_once(cache)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, err, status = Open3.capture3({ "HECKS_CACHE_DIR" => cache }, "ruby", "-I", "lib", "-e", PROGRAM, chdir: root)
    raise "launcher failed: #{err}" unless status.success?

    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def warm_median(cache)
    spawn_once(cache)
    times = Array.new(RUNS) { spawn_once(cache) }.sort
    times[RUNS / 2]
  end

  it "answers a warm bare hecks under the ceiling" do
    Dir.mktmpdir do |cache|
      median = warm_median(cache)
      expect(median).to be < CEILING_SECONDS, "warm median #{median.round(2)}s exceeds #{CEILING_SECONDS}s"
    end
  end
end

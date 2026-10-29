# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "hecks/tools/regeneration_run"

# The pool a corpus regeneration forks its domains through. The codegen is replaced by a runner that
# says what it was asked, so what is under test is the pool: how many children run at once, the
# order their output is printed in, and what a failing child does to the run.
#
# A child's output is what it writes to stderr, which the pool collects with its stdout. Children
# wait for one another on pipes the example makes before the fork, so no example waits on a clock.
RSpec.describe Hecks::Tools::RegenerationRun::Pool do
  let(:flags) { ["--declared=a,b", "--default=b", "--partial"] }

  # How long an example waits for a child that should have said something, and for one that
  # should not.
  def patience = 10
  def pause = 0.5

  def run_pool(domains, workers, runner)
    described_class.new(domains, flags, workers, runner: runner).call
  end

  # What a run printed and what it aborted with: [stdout, stderr], however it ended.
  def printed(domains, workers, runner)
    out = nil
    err = capture_stderr { out = capture_stdout { aborted { run_pool(domains, workers, runner) } } }
    [out, err]
  end

  def aborted
    yield
  rescue SystemExit
    nil
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # A runner that says its domain's name and ends with `status` for the domains in `failing`.
  def failing(failing, status: 1)
    lambda do |argv|
      warn "output of #{argv.first}"
      failing.include?(argv.first) ? status : 0
    end
  end

  # Waits for a byte on `pipe`, giving up after `patience` seconds.
  def await(pipe)
    pipe.read(1) if pipe.wait_readable(patience)
  end

  describe "the order of the output" do
    # `slow` finishes after `mid`, which finishes after `fast`: each waits for the next to say go.
    def reversed
      slow_go, slow_release = IO.pipe
      mid_go, mid_release = IO.pipe
      lambda do |argv|
        await({ "slow" => slow_go, "mid" => mid_go }[argv.first]) if argv.first != "fast"
        warn "output of #{argv.first}"
        { "fast" => mid_release, "mid" => slow_release }[argv.first]&.write("x")
        0
      end
    end

    def in_domain_order
      %w[slow mid fast].map { |name| "== hecks project_rust #{name} ==\noutput of #{name}\n\n" }.join
    end

    it "is each domain's output whole and in domain order, however they finish" do
      expect(printed(%w[slow mid fast], 3, reversed).first).to eq(in_domain_order)
    end
  end

  it "gives each child the domain first and then the declared flags" do
    runner = lambda do |argv|
      warn argv.join(" ")
      0
    end

    expect(printed(%w[x/a], 1, runner).first).to include("x/a --declared=a,b --default=b --partial")
  end

  describe "how many run at once" do
    # Children say they started, then wait to be let go; the example lets them go one at a time.
    let(:started) { IO.pipe }
    let(:release) { IO.pipe }

    def holding(failing: [])
      started_writer = started.last
      release_reader = release.first
      lambda do |argv|
        started_writer.write("#{argv.first}\n")
        await(release_reader) unless failing.include?(argv.first)
        failing.include?(argv.first) ? 1 : 0
      end
    end

    # The next domain to say it started, nil when none does within `wait` seconds.
    def next_started(wait = patience)
      started.first.gets.to_s.chomp if started.first.wait_readable(wait)
    end

    def started_names(count) = Array.new(count) { next_started }.sort

    def run_in_background(domains, workers, runner)
      @run = Thread.new { printed(domains, workers, runner) }
    end

    def release_all(count) = count.times { release.last.write("x") }

    # Lets every child still waiting go, so no example leaves one behind.
    after do
      release_all(10)
      @run&.join
    end

    it "is no more than `workers`", :aggregate_failures do
      run_in_background(%w[a b c d], 2, holding)

      expect(started_names(2)).to eq(%w[a b])
      expect(next_started(pause)).to be_nil
    end

    it "starts the next domain as soon as one ends" do
      run_in_background(%w[a b c], 2, holding)
      started_names(2)
      release_all(1)

      expect(next_started).to eq("c")
    end

    it "is all of them side by side when there are workers enough" do
      run_in_background(%w[a b c], 3, holding)

      expect(started_names(3)).to eq(%w[a b c])
    end

    # Four domains on two workers, `b` failing at once while `a` is still held. The pool is given
    # a moment to start the next domain, then `a` is let go; answers the run's output.
    def run_with_b_failing
      run_in_background(%w[a b c d], 2, holding(failing: %w[b]))
      started_names(2)
      @third = next_started(pause)
      release_all(1)
      @run.value
    end

    it "starts nothing more after a failure, and lets the children already running finish", :aggregate_failures do
      out, err = run_with_b_failing

      expect(@third).to be_nil
      expect(out).to include("== hecks project_rust a ==")
      expect(out).not_to include("project_rust c", "project_rust d")
      expect(err).to include("hecks project_rust b failed")
    end
  end

  describe "a failing child" do
    it "fails the run naming the domain, after printing its output", :aggregate_failures do
      out, err = printed(%w[a b c], 1, failing(%w[b]))

      expect(err).to match(/hecks regenerate_corpus: hecks project_rust b failed \(#<Process::Status: pid \d+ exit 1>\)/)
      expect(out).to include("== hecks project_rust b ==\noutput of b\n")
    end

    it "stops the run before the next domain when they run one at a time" do
      out, = printed(%w[a b c], 1, failing(%w[b]))

      expect(out).not_to include("project_rust c")
    end

    it "names every domain that failed", :aggregate_failures do
      _, err = printed(%w[a b], 2, failing(%w[a b]))

      expect(err).to include("hecks project_rust a failed")
      expect(err).to include("(also failed: b)")
    end

    it "reports the exit status the child ended with" do
      _, err = printed(%w[a], 1, failing(%w[a], status: 3))

      expect(err).to include("exit 3")
    end

    it "reports a child that raises, showing what it said", :aggregate_failures do
      out, err = printed(%w[a], 1, ->(_argv) { raise "kaboom" })

      expect(out).to include("RuntimeError: kaboom")
      expect(err).to include("project_rust a failed")
    end
  end

  it "does not abort when every child succeeds" do
    expect { capture_stdout { run_pool(%w[a b], 2, failing([])) } }.not_to raise_error
  end
end

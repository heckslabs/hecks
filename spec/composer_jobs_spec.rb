require "spec_helper"
require "hecks/composer/jobs"

# The jobs runner holds one background command at a time; the page polls its state.
RSpec.describe Hecks::Composer::Jobs do
  let(:gate)    { Queue.new }
  let(:started) { Queue.new }
  let(:idle)    { Queue.new }

  def blocking
    lambda do |**|
      started << true
      gate.pop
      { ok: true, status: 0, output: "all clear" }
    end
  end

  def jobs(runner = blocking, timeout: 600) = described_class.new(runner: runner, timeout: timeout)

  def begin_job(subject_jobs) = subject_jobs.start(kind: "hecks", verb: "fuzz")

  def running_job
    jobs.tap do |runner|
      begin_job(runner)
      started.pop(timeout: 2)
    end
  end

  def finish(runner)
    gate << true
    await(runner, "done")
  end

  def await(subject_jobs, status)
    200.times do
      return subject_jobs.state if subject_jobs.state[:status] == status

      idle.pop(timeout: 0.01)
    end
    subject_jobs.state
  end

  def long_output = "#{"a" * 30_000}end"

  it "starts idle", :aggregate_failures do
    state = jobs.state

    expect(state[:status]).to eq("idle")
    expect(state.values_at(:verb, :started_at, :finished_at, :ok)).to all(be_nil)
  end

  it "reports running while the runner holds", :aggregate_failures do
    runner = jobs
    expect(begin_job(runner)).to be(true)
    started.pop(timeout: 2)
    expect(runner.state).to include(status: "running", verb: "fuzz", ok: nil)
    finish(runner)
  end

  it "reports done with the output and a finish time", :aggregate_failures do
    runner = running_job

    expect(finish(runner)).to include(ok: true, output: "all clear")
    expect(Time.iso8601(runner.state[:finished_at])).to be_a(Time)
  end

  it "hands the runner its keywords" do
    runner = jobs(->(**call) { { ok: true, status: 0, output: call.inspect } })
    runner.start(kind: "hecks", verb: "fuzz", args: { n: 1 }, confirm: "yes")
    expect(await(runner, "done")[:output]).to eq({ kind: "hecks", verb: "fuzz", args: { n: 1 }, confirm: "yes" }.inspect)
  end

  it "fails when the runner reports not ok", :aggregate_failures do
    runner = jobs(->(**) { { ok: false, status: 1, output: "boom" } })
    begin_job(runner)
    expect(await(runner, "failed")).to include(ok: false, output: "boom")
  end

  it "fails with the message when the runner raises", :aggregate_failures do
    runner = jobs(->(**) { raise "exploded" })
    begin_job(runner)
    expect(await(runner, "failed")).to include(ok: false, output: "exploded")
  end

  it "keeps only the last of a long output" do
    runner = jobs(->(**) { { ok: true, status: 0, output: long_output } })
    begin_job(runner)
    expect(await(runner, "done")[:output]).to match(/\Aa{19997}end\z/)
  end

  it "refuses a second start while one runs" do
    runner = running_job
    expect { begin_job(runner) }.to raise_error(described_class::Busy)
    finish(runner)
  end

  it "cancels a running job", :aggregate_failures do
    runner = running_job

    expect(runner.cancel).to be(true)
    expect(runner.state).to include(status: "cancelled", ok: false)
    expect(runner.cancel).to be(false)
  end

  it "times out a job that never returns", :aggregate_failures do
    runner = jobs(timeout: 0.2)
    begin_job(runner)
    expect(await(runner, "timed_out")).to include(status: "timed_out", ok: false)
    expect(runner.state[:output]).to include("timed out")
  end

  it "starts again after a job is done", :aggregate_failures do
    runner = jobs(->(**) { { ok: true, status: 0, output: "again" } })
    begin_job(runner)
    await(runner, "done")
    expect(begin_job(runner)).to be(true)
    expect(await(runner, "done")).to include(output: "again")
  end
end

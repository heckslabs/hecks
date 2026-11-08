require "spec_helper"

# Early CI: a landed branch is recorded for an early run under ci/<branch>, the switch turns it off,
# main is never started, and a CI result is kept on the record. The domain is in Memory.
RSpec.describe "early CI record" do
  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def start(run, branch, *extra)
    out, = launch("EarlyCi.start!", "run.value=#{run}", "branch.value=#{branch}", *extra, "--wait")
    out.to_s
  end

  it "records a landed coder branch", :aggregate_failures do
    out = start("ec-1", "coder-x")
    expect(out).to include("EarlyCiStarted")
    expect(out).to include("requested")
  end

  it "refuses main" do
    expect(start("ec-2", "main")).not_to include("EarlyCiStarted")
  end

  it "refuses to start when the switch is off" do
    expect(start("ec-3", "coder-y", "early_ci.value=false")).not_to include("EarlyCiStarted")
  end

  it "keeps what CI said of the branch" do
    start("ec-4", "coder-z")
    launch("EarlyCi.open!", "to=ec-4", "number.value=12", "--wait")
    out, = launch("EarlyCi.observe!", "to=ec-4", "outcome.value=passed", "report.value=ok", "--wait")
    expect(out.to_s).to include("EarlyCiObserved")
  end
end

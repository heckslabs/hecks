require "spec_helper"

# The Work queue as a coder's intake: a session claims the oldest planned step, and a submitted
# branch named for the step finishes it. Each example boots its own Hecks domain, so no claim or
# step leaks into another.
RSpec.describe "the Work queue" do
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false) }

  def cli_text(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def run_cli(*argv)
    JSON.parse(cli_text(*argv))
  end

  def plan(key, step: nil)
    run_cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}", "detail.value=The brief for #{key}",
            *(step ? ["step.value=#{step}"] : []))
  end

  def start(key, by: "session-a")
    run_cli("work.start!", "to=#{key}", "claimed_by.value=#{by}", "claimed_at.value=2026-10-31T09:00:00Z")
  end

  def start_text(key, by: "session-a")
    cli_text("work.start!", "to=#{key}", "claimed_by.value=#{by}", "claimed_at.value=2026-10-31T09:00:00Z")
  end

  def status_of(key)
    run_cli("work.undone").find { |row| row["work"] == key }&.fetch("status")
  end

  it "records the claimant and the claim time on a started step", :aggregate_failures do
    plan("work/claim-1")
    state = start("work/claim-1").fetch("state")

    expect(state["status"]).to eq("started")
    expect(state["claimed_by"]).to eq("session-a")
  end

  it "refuses a second claim on a started step by naming its state" do
    plan("work/claim-2")
    start("work/claim-2")

    expect(start_text("work/claim-2", by: "session-b")).to match(/lifecycle_refused.*"started"/)
  end

  it "returns the oldest planned step as the next brief", :aggregate_failures do
    plan("work/later", step: 2)
    plan("work/first", step: 1)

    expect(run_cli("work.next_planned").first.values_at("work", "detail")).to eq(["work/first", "The brief for work/first"])
  end

  it "skips a step already claimed when it names the next planned one" do
    plan("work/taken", step: 1)
    plan("work/free", step: 2)
    start("work/taken")

    expect(run_cli("work.next_planned").first["work"]).to eq("work/free")
  end

  it "finishes the step a submitted branch names" do
    plan("work/submitted", step: 1)
    state = run_cli("work.finish!", "to=work/submitted").fetch("state")

    expect(state["status"]).to eq("done")
  end

  it "refuses a submission whose branch names no step, by naming Work" do
    expect(cli_text("work.finish!", "to=work/none")).to include("not_found] no Work")
  end

  it "routes a submitted branch to Finish through the policy, with no parsing", :aggregate_failures do
    policy = hecks.registry.bluebook("Tickets").policies.find { |pol| pol.hecks_name == "FinishWhenWorkSubmitted" }

    expect(policy.event_name).to eq("WorkSubmitted")
    expect(policy.trigger_command).to eq("Work.Finish")
  end

  it "returns a started step to planned when its claim goes stale" do
    plan("work/stale")
    start("work/stale")
    run_cli("work.release!", "to=work/stale")

    expect(status_of("work/stale")).to eq("planned")
  end
end

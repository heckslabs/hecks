require "spec_helper"

# A coder's wrap-up: releasing a started work item needs one, and the next session that claims
# the item reads it. Each example boots its own Hecks domain.
RSpec.describe "a coder's wrap-up on a released work item" do
  let(:hecks) { boot_hecks_in_memory }

  def cli_text(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def run_cli(*argv)
    JSON.parse(cli_text(*argv))
  end

  def started(key)
    run_cli("work.plan!", "work.value=#{key}", "title.value=Item #{key}")
    run_cli("work.start!", "to=#{key}", "claimed_by.value=session-a", "claimed_at.value=2026-11-28T09:00:00Z")
  end

  def row(key) = run_cli("work.undone").find { |work| work["work"] == key }

  def release(key, wrap_up)
    cli_text("work.release!", "to=#{key}", *(wrap_up ? ["wrap_up.value=#{wrap_up}"] : []))
  end

  it "refuses a release that carries no wrap-up" do
    started("wrap/none")

    expect(release("wrap/none", nil)).to include("refused")
  end

  it "refuses a release whose wrap-up is empty and leaves the item started" do
    started("wrap/blank")
    release("wrap/blank", "")

    expect(row("wrap/blank")["status"]).to eq("started")
  end

  it "keeps the wrap-up on the planned item for the session that claims it next" do
    started("wrap/kept")
    release("wrap/kept", "did the bluebook; left the spec; watch the ledger")
    run_cli("work.start!", "to=wrap/kept", "claimed_by.value=session-b", "claimed_at.value=2026-11-28T10:00:00Z")

    expect(row("wrap/kept").values_at("status", "wrap_up"))
      .to eq(["started", "did the bluebook; left the spec; watch the ledger"])
  end
end

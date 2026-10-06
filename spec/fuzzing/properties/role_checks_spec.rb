require "spec_helper"
require "hecks/fuzzing"

# `Properties.role_checks_agree_with_grants`. The passing and failing verdicts hand-build a
# `role_checks` list; one real replay shows the recorder reads a live grant back off Governance.
RSpec.describe "Hecks::Fuzzing::Properties.role_checks_agree_with_grants", :aggregate_failures do
  def banking_path = File.join(InMemoryDomain::ROOT, "examples/banking")

  def verdict(role_checks) = Hecks::Fuzzing::Properties.role_checks_agree_with_grants(role_checks: role_checks)

  def unauthorized = Hecks::Fuzzing::Properties::RoleChecks::UNAUTHORIZED

  def check(grants:, outcome:)
    { verb: "Banking::Customer.Register", role: "Branch clerk", actor_id: "alice", grants: grants, outcome: outcome }
  end

  def live_grant = { role: "Branch clerk", ended: false }

  it "passes a history with no identified-caller checks" do
    expect(verdict([])).to be(true)
  end

  it "passes a live grant that was accepted" do
    expect(verdict([check(grants: [live_grant], outcome: nil)])).to be(true)
  end

  it "passes no grant and a refusal for unauthorized" do
    expect(verdict([check(grants: [], outcome: unauthorized)])).to be(true)
  end

  it "names a dispatch refused as unauthorized though the actor holds a live grant" do
    result = verdict([check(grants: [live_grant], outcome: unauthorized)])

    expect(result).to be_a(String).and include("refused as unauthorized", "alice", "Branch clerk")
  end

  it "names a dispatch accepted though the actor holds no live grant" do
    result = verdict([check(grants: [], outcome: nil)])

    expect(result).to be_a(String).and include("was accepted", "holds no live grant")
  end

  it "treats an ended grant as no grant" do
    ended = { role: "Branch clerk", ended: true }

    expect(verdict([check(grants: [ended], outcome: nil)])).to be_a(String).and include("holds no live grant")
  end

  it "reads only a grant of the command's own role" do
    other = { role: "Teller", ended: false }

    expect(verdict([check(grants: [other], outcome: nil)])).to be_a(String)
  end

  it "draws no conclusion from a refusal other than unauthorized" do
    refused_earlier = check(grants: [], outcome: "Hecks::Runtime::AbsentArgument")

    expect(verdict([refused_earlier])).to be(true)
  end

  # Not hand-built: the first grant comes from a caller with no actor_id (string-compared), then
  # the granted actor registers a customer through the grant-checked path.
  def assign_step
    { "verb" => "Governance::RoleAssignment.Assign", "role" => "Governance administrator",
      "args" => { "actor_id" => { "value" => "alice" }, "role_name" => { "value" => "Branch clerk" },
                  "scope" => { "value" => "all" }, "starts_at" => { "value" => "2020-01-01T00:00:00Z" } } }
  end

  def register_step
    { "verb" => "Banking::Customer.Register", "role" => "Branch clerk", "actor_id" => "alice",
      "args" => { "reference" => { "value" => "ROLE-#{rand(1_000_000_000)}" },
                  "name"      => { "given" => "Ada", "family" => "Lovelace" },
                  "email"     => { "address" => "ada@example.com" } } }
  end

  it "records a granted actor's check from a real replay, and agrees with it" do
    replayed = Hecks::Fuzzing::Replay.call(banking_path, [assign_step, register_step])

    expect(replayed[:refusals]).to eq([])
    expect(replayed[:role_checks].map { |c| [c[:actor_id], c[:role], c[:outcome]] }).to eq([["alice", "Branch clerk", nil]])
    expect(replayed[:role_checks].first[:grants]).to eq([{ role: "Branch clerk", ended: false }])
    expect(Hecks::Fuzzing::Properties.role_checks_agree_with_grants(replayed)).to be(true)
  end

  it "records an ungranted actor's refused check from a real replay, and agrees with it" do
    replayed = Hecks::Fuzzing::Replay.call(banking_path, [register_step])

    expect(replayed[:role_checks].map { |c| c[:outcome] }).to eq([unauthorized])
    expect(Hecks::Fuzzing::Properties.role_checks_agree_with_grants(replayed)).to be(true)
  end
end

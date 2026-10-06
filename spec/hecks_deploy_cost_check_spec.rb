require "spec_helper"
require "json"

# `hecks deploy cost_check.check` end to end: the Deploy chapter's CostCheck asks the CostExplorer
# port, the Hecks domain binds its adapter, and the answer or the refusal is recorded on the check.
# `aws` is stubbed, so the readings here are what the stub returns and nothing reaches AWS.
RSpec.describe "the Deploy chapter's CostCheck" do
  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  let(:ok)  { instance_double(Process::Status, success?: true) }
  let(:red) { instance_double(Process::Status, success?: false) }

  def day(date, dollars)
    { "TimePeriod" => { "Start" => date },
      "Groups"     => [{ "Keys" => ["Amazon RDS"], "Metrics" => { "UnblendedCost" => { "Amount" => dollars.to_s } } }] }
  end

  def stub_aws(rows: [], err: "", status: ok)
    allow(Open3).to receive(:capture3).and_return([JSON.generate("ResultsByTime" => rows), err, status])
  end

  def run_check(*argv)
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "cost_check.check", *argv, "--wait"])
    [JSON.parse(out), status]
  end

  it "is declared in the Deploy chapter, with the CostExplorer port it asks" do
    bluebook = @hecks.registry.bluebook("Deploy")

    expect(bluebook.aggregate("CostCheck").commands.map(&:hecks_name)).to eq(%w[Check Pass Flag])
  end

  it "records a monthly rate within the budget as within_budget, with the report", :aggregate_failures do
    stub_aws(rows: [day("2026-10-05", 2.4), day("2026-10-06", 2.4)])

    json, status = run_check("budget=75", "since=2020-01-01")

    expect(status).to eq(0)
    expect(json.dig("state", "status")).to eq("within_budget")
    expect(json.dig("state", "report", "value")).to include("(2 days)", "$2.40/day", "against $75", "Amazon RDS")
  end

  it "records a monthly rate over the budget as flagged, exits 1 under --wait, and says what it was", :aggregate_failures do
    stub_aws(rows: [day("2026-10-05", 5.0)])

    json, status = run_check("budget=75", "since=2020-01-01")

    expect(status).to eq(1)
    expect(json.dig("state", "status")).to eq("flagged")
    expect(json.dig("state", "refusal", "value")).to include("over budget:", "$5.00/day", "$152.19/month against $75")
  end

  it "flags a reading it could not take, with the reason aws gave", :aggregate_failures do
    stub_aws(err: "Unable to locate credentials", status: red)

    json, status = run_check("budget=75", "since=2020-01-01")

    expect(status).to eq(1)
    expect(json.dig("state", "status")).to eq("flagged")
    expect(json.dig("state", "refusal", "value")).to include("Unable to locate credentials")
  end

  def refusal_for(argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                 argv: ["deploy", "cost_check.check", *argv, "--wait"])
  end

  def expect_refused(argv, message)
    out, status = refusal_for(argv)

    expect(status).not_to eq(0)
    expect(out).to match(message)
  end

  def refused_argvs
    { %w[budget=0 since=2020-01-01] => /a budget is positive/, %w[budget=75 since=October] => /since/i }
  end

  it "refuses a budget that is not positive and a day that is not a date, before anything is asked", :aggregate_failures do
    allow(Open3).to receive(:capture3)

    refused_argvs.each { |argv, message| expect_refused(argv, message) }
    expect(Open3).not_to have_received(:capture3)
  end
end

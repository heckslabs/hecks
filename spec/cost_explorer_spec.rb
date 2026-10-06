require "spec_helper"
require "hecks/hecks/adapters/cost_explorer"

# The CostExplorer port's adapter reads what an account has billed with `aws` and compares the
# monthly rate to a budget. These examples stub `aws`, recording each call, so nothing here reaches
# AWS.
RSpec.describe Hecks::Adapters::CostExplorer do
  let(:adapter) { described_class.new(settings: { today: "2026-10-07" }) }
  let(:ok)      { instance_double(Process::Status, success?: true) }
  let(:red)     { instance_double(Process::Status, success?: false) }
  let(:calls)   { [] }

  def day(date, **services)
    { "TimePeriod" => { "Start" => date },
      "Groups"     => services.map do |name, dollars|
        { "Keys" => [name.to_s], "Metrics" => { "UnblendedCost" => { "Amount" => dollars.to_s } } }
      end }
  end

  def stub_aws(rows: nil, err: "", status: ok)
    allow(Open3).to receive(:capture3) do |*arguments|
      calls << arguments
      [JSON.generate("ResultsByTime" => rows || []), err, status]
    end
  end

  def check(budget: 75, since: "2026-10-05") = adapter.measure(budget: { value: budget }, since: { value: since })

  it "answers a one-line report when the monthly rate is within the budget", :aggregate_failures do
    stub_aws(rows: [day("2026-10-05", RDS: 1.2, EC2: 0.9, WAF: 0.3), day("2026-10-06", RDS: 1.2, EC2: 0.9, WAF: 0.3)])

    answer = check

    expect(answer.keys).to eq([:report])
    expect(answer[:report][:value]).to include("2026-10-05..2026-10-06 (2 days)", "$2.40/day", "$73.05/month against $75",
                                               "biggest: RDS $1.20/day, EC2 $0.90/day, WAF $0.30/day")
  end

  def expected_cost_call
    ["aws", "ce", "get-cost-and-usage", "--time-period", "Start=2026-10-05,End=2026-10-07", "--granularity", "DAILY",
     "--metrics", "UnblendedCost", "--group-by", "Type=DIMENSION,Key=SERVICE", "--output", "json"]
  end

  it "asks for the daily cost by service from the first day up to today, which is left out" do
    stub_aws(rows: [day("2026-10-05", RDS: 2.0)])

    check

    expect(calls.first).to eq(expected_cost_call)
  end

  it "refuses with the figures when the monthly rate is over the budget" do
    stub_aws(rows: [day("2026-10-05", RDS: 3.0), day("2026-10-06", RDS: 3.0)])

    expect { check }.to raise_error(RuntimeError, %r{\Aover budget: .*\$3\.00/day, \$91\.31/month against \$75})
  end

  it "takes a budget and a day given as plain values" do
    stub_aws(rows: [day("2026-10-06", RDS: 1.0)])

    expect(adapter.measure(budget: 75, since: "2026-10-06")[:report][:value]).to include("(1 days)")
  end

  it "refuses when no complete day has passed since the day", :aggregate_failures do
    stub_aws

    expect { check(since: "2026-10-07") }.to raise_error(RuntimeError, /no complete day since 2026-10-07/)
    expect(calls).to be_empty
  end

  it "refuses when aws fails, saying what it said" do
    stub_aws(err: "Unable to locate credentials", status: red)

    expect { check }.to raise_error(RuntimeError, /get-cost-and-usage failed: Unable to locate credentials/)
  end

  it "refuses when Cost Explorer returns no days" do
    stub_aws(rows: [])

    expect { check }.to raise_error(RuntimeError, /returned no days for 2026-10-05\.\.2026-10-07/)
  end
end

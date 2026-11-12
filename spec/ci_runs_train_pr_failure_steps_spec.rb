require "spec_helper"
require "json"
require "hecks/hecks/adapters/ci_runs"

# The failed jobs of a train pull request's attempt are on the failure's facts before it is rerun.
RSpec.describe Hecks::Adapters::CiRuns::TrainPrFailure, "#facts" do
  let(:log) { "Failure/Error: x\nrspec ./spec/x_spec.rb:12 # fails\n3 examples, 1 failure" }
  let(:jobs) { [{ "databaseId" => 9, "name" => "rspec_shard (3)", "conclusion" => "failure", "steps" => [] }] }

  def host
    lambda do |argv, **|
      return [true, JSON.generate([{ "databaseId" => 7, "attempt" => 1 }])] if argv[2] == "list"
      return [true, JSON.generate({ "jobs" => jobs })] if argv.include?("--json")

      [true, log]
    end
  end

  def facts = described_class.new(host, Dir.pwd, "train/main-abc", "abcdef0123456789").facts({ "number" => 1358 })

  it "names the failed job of a spec failure" do
    expect(facts[:step]).to eq("rspec_shard (3)")
  end

  it "keeps the spec file as the identity", :aggregate_failures do
    expect(facts[:specs]).to eq("spec/x_spec.rb")
    expect(facts[:cause]).to eq("spec")
  end
end

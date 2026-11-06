require "spec_helper"
require "json"

RSpec.describe Hecks::Adapters::GitTrain::PrQueue do
  COMMIT_FOR_QUEUE = "0123456789abcdef0123456789abcdef01234567".freeze

  def runner(view)
    calls = []
    run = lambda do |argv, chdir: nil|
      calls << argv
      argv[1] == "view" ? [true, JSON.generate(view)] : [true, ""]
    end
    [run, calls]
  end

  def clean_view(checks: [])
    { "isDraft" => false, "mergeStateStatus" => "CLEAN", "statusCheckRollup" => checks }
  end

  it "queues a clean pull request to merge" do
    run, calls = runner(clean_view(checks: [{ "status" => "COMPLETED", "conclusion" => "SUCCESS" }]))
    answer = described_class.new(run, "/tmp").answer(COMMIT_FOR_QUEUE)

    expect(answer[:outcome]).to eq(value: "queued")
    expect(calls.last).to include("merge", "--auto")
  end

  it "refuses a pull request with a failed check, and queues nothing" do
    run, calls = runner(clean_view(checks: [{ "status" => "COMPLETED", "conclusion" => "FAILURE" }]))
    answer = described_class.new(run, "/tmp").answer(COMMIT_FOR_QUEUE)

    expect(answer[:outcome]).to eq(value: "refused")
    expect(answer[:report][:value]).to include("a check failed")
    expect(calls.map { |argv| argv[1] }).not_to include("merge")
  end

  it "refuses a pull request still running a check" do
    run, = runner(clean_view(checks: [{ "status" => "IN_PROGRESS", "conclusion" => nil }]))

    expect(described_class.new(run, "/tmp").answer(COMMIT_FOR_QUEUE)[:report][:value]).to include("still running")
  end
end

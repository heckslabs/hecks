require "spec_helper"
require "tmpdir"
require "hecks/composer"
require "hecks/composer/behavior_run"

# The behaviors runner stages a workspace, runs its `.behaviors` files and reports each test as
# plain data, so the page can show what passes before anything is saved.
RSpec.describe Hecks::Composer::BehaviorRun do
  let(:dir)  { File.expand_path("fixtures/composer/behaviors", __dir__) }
  let(:file) { "ledger.behaviors" }

  def source = File.read(File.join(dir, file))

  def run_with(text = nil) = described_class.call(dir: dir, buffers: text ? { file => text } : {})

  def runs_of(result) = result[:files].flat_map { |entry| entry[:runs] }

  it "passes the saved tests, naming the file relative to the workspace", :aggregate_failures do
    result = run_with

    expect(result[:files].map { |entry| entry[:path] }).to eq([file])
    expect(result[:summary]).to eq(total: 2, passed: 2, failed: 0, errored: 0, parse_errors: 0)
  end

  it "reports status as a string with the test's description", :aggregate_failures do
    run = runs_of(run_with).first

    expect(run[:status]).to eq("pass")
    expect(run[:description]).to include("Open")
  end

  it "counts unsaved text, so an edited expectation fails", :aggregate_failures do
    result = run_with(source.sub('expect status: "open"', 'expect status: "frozen"'))

    expect(result[:summary]).to include(passed: 1, failed: 1)
    expect(runs_of(result).map { |run| run[:status] }).to contain_exactly("pass", "fail")
  end

  it "leaves the saved file alone" do
    run_with(source.sub("open", "closed"))

    expect(File.read(File.join(dir, file))).to eq(source)
  end

  it "reports a workspace with no behaviors file as empty", :aggregate_failures do
    Dir.mktmpdir("composer-no-behaviors") do |empty|
      result = described_class.call(dir: empty)

      expect(result[:files]).to eq([])
      expect(result[:summary]).to eq(total: 0, passed: 0, failed: 0, errored: 0, parse_errors: 0)
    end
  end

  it "reports a behaviors file that does not parse without raising", :aggregate_failures do
    result = run_with("Hecks.behaviors \"Ledger\" do\n  test (\nend\n")

    expect(result[:files].first[:parse_error]).to be_a(String)
    expect(result[:summary]).to include(parse_errors: 1, total: 0)
  end
end

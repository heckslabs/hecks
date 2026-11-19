require "spec_helper"
require "hecks/agents/adapters/submitted_paths"

# The `SubmittedPaths` adapter reads the paths a commit changed against main with git, each between
# bars so the bluebook's given matches a path whole, and the commit's tree.
RSpec.describe Hecks::Adapters::SubmittedPaths do
  def status(success) = instance_double(Process::Status, success?: success)

  def adapter(out: "", err: "", success: true, calls: [])
    described_class.new(git: ->(argv) { (calls << argv) && [out, err, status(success)] })
  end

  it "answers each changed path between bars" do
    answer = adapter(out: "a.bluebook\nb.rb\n").submitted_paths(review: { value: "abc1234" }, checkout: "/co")
    expect(answer[:paths]).to eq(value: "|a.bluebook|b.rb|")
  end

  it "answers the commit's tree" do
    answer = adapter(out: "7ee1\n").submitted_paths(review: "abc1234", checkout: "/co")
    expect(answer[:tree]).to eq(value: "7ee1")
  end

  it "asks git for the diff against main and the tree, in the checkout" do
    calls = []
    adapter(calls: calls).submitted_paths(review: "abc1234", checkout: { value: "/co" })
    expect(calls).to eq([%w[git -C /co diff --name-only main...abc1234], %w[git -C /co rev-parse abc1234^{tree}]])
  end

  it "refuses by name when git cannot read the paths" do
    expect { adapter(err: "bad revision\n", success: false).submitted_paths(review: "abc1234", checkout: "/co") }
      .to raise_error(described_class::Unread, "git could not read the paths abc1234 changed: bad revision")
  end
end

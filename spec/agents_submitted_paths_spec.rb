require "spec_helper"
require "hecks/agents/adapters/submitted_paths"

# The `SubmittedPaths` adapter reads the paths a commit changed against main with git, and answers
# each between bars, so the bluebook's given matches a path whole.
RSpec.describe Hecks::Adapters::SubmittedPaths do
  def status(success) = instance_double(Process::Status, success?: success)

  def adapter(out: "", err: "", success: true, calls: [])
    described_class.new(git: ->(argv) { (calls << argv) && [out, err, status(success)] })
  end

  it "answers each changed path between bars" do
    answer = adapter(out: "a.bluebook\nb.rb\n").submitted_paths(review: { value: "abc1234" }, checkout: "/co")
    expect(answer).to eq(paths: { value: "|a.bluebook|b.rb|" })
  end

  it "asks git for the diff of the commit against main, in the checkout" do
    calls = []
    adapter(calls: calls).submitted_paths(review: "abc1234", checkout: { value: "/co" })
    expect(calls).to eq([%w[git -C /co diff --name-only main...abc1234]])
  end

  it "refuses by name when git cannot read the paths" do
    expect { adapter(err: "bad revision\n", success: false).submitted_paths(review: "abc1234", checkout: "/co") }
      .to raise_error(described_class::Unread, "git could not read the paths abc1234 changed: bad revision")
  end
end

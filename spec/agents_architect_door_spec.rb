require "spec_helper"

# The architect's restricted door serves the Agents domain beside Hecks, so the `Diff` query it
# is told to read is one it can reach.
RSpec.describe "the architect's door" do
  let(:file) { File.read(File.join(InMemoryDomain::ROOT, ".claude/agents/architect.md")) }

  it "serves the Agents domain, where change_review.diff is answered" do
    expect(file[/HECKS_SERVER_DOMAINS: (\S+)/, 1].split(":")).to include("lib/hecks/agents")
  end
end

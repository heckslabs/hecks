require "spec_helper"

# The architect's restricted door serves every domain under lib/hecks, so the `Diff` query it is
# told to read, in the Agents domain, is one it can reach.
RSpec.describe "the architect's door" do
  let(:file)    { File.read(File.join(InMemoryDomain::ROOT, ".claude/agents/architect.md")) }
  let(:domains) { file[/HECKS_SERVER_DOMAINS: (\S+)/, 1].split(":") }

  it "serves all of lib/hecks, which holds the Agents domain where change_review.diff is answered" do
    expect(domains).to eq(["lib/hecks"])
  end
end

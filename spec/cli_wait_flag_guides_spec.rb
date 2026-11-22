require "spec_helper"

# A command that returns at status requested without `--wait` says so in its CLI guide, so a reader
# who runs ModelCheck or RunBehaviors knows to pass `--wait` to read the verdict.
RSpec.describe "the CLI guides for the checking commands" do
  let(:guides) { File.join(InMemoryDomain::ROOT, "docs/implemented/guides/cli") }
  let(:advice) { "without --wait it returns at status requested, so pass --wait to read the verdict" }

  it "tells the reader of ModelCheck to pass --wait to read the verdict" do
    expect(File.read(File.join(guides, "check.md"))).to include(advice)
  end

  it "tells the reader of RunBehaviors to pass --wait to read the verdict" do
    expect(File.read(File.join(guides, "operate.md"))).to include(advice)
  end
end

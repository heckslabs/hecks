require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/git_rehearsal"

# Which impacted specs a rehearsal cannot run here.
RSpec.describe Hecks::Adapters::GitRehearsal::Impacted::Skips do
  let(:root) { Dir.mktmpdir("hecks-skips") }
  let(:reachable) { false }
  let(:skips) { described_class.new(root, scratch: -> { reachable }) }

  after { FileUtils.remove_entry(root) }

  def spec(text) = File.write(File.join(root, "a_spec.rb"), text).then { "a_spec.rb" }

  it "leaves out a spec that builds with cargo" do
    expect(skips.call(spec(%(system("cargo build")\n)))).to eq("needs cargo")
  end

  it "leaves out a spec that drives gh" do
    expect(skips.call(spec(%(system("gh", "pr", "list")\n)))).to eq("needs gh")
  end

  it "leaves out an io spec when no scratch Postgres answers" do
    expect(skips.call(spec("RSpec.describe X, :io do\nend\n"))).to eq("no scratch Postgres")
  end

  context "when a scratch Postgres answers" do
    let(:reachable) { true }

    it "runs the io spec" do
      expect(skips.call(spec("RSpec.describe X, :io do\nend\n"))).to be_nil
    end
  end
end

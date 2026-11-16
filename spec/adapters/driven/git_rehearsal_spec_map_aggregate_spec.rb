require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_rehearsal"

# A policy declared at the domain level reacts to an aggregate it is not nested in (AgentRun,
# commit 81c62ca44). Each aggregate a changed line names selects the specs that name it, which
# may be broad; the map's limit bounds the run.
RSpec.describe Hecks::Adapters::GitRehearsal::SpecMap do
  let(:root) { Dir.mktmpdir("hecks-spec-map-aggregate") }
  let(:path) { "lib/hecks/hecks/delegate/delegate.bluebook" }
  let(:policy) { "policy \"Settle\" do\n  on \"AgentRun.JobRead\"\n  trigger AgentRun::Retire\nend\n" }

  def git(*args) = Open3.capture2e("git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t", *args)

  def write(file, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, file)))
    File.write(File.join(root, file), text)
  end

  def start
    git("init", "-q", "-b", "main")
    write(path, "aggregate \"Shed\" do\nend\n")
    write("spec/agent_run_spec.rb", "RSpec.describe \"AgentRun\"\n")
    write("spec/unrelated_spec.rb", "# nothing\n")
    git("add", "-A") && git("commit", "-q", "-m", "base")
    write(path, "aggregate \"Shed\" do\nend\n#{policy}")
  end

  def mapping = described_class.new(root).map([path], limit: 60, since: "HEAD")

  before { start }

  after { FileUtils.remove_entry(root) }

  it "selects the spec that names the aggregate" do
    expect(mapping.specs).to include("spec/agent_run_spec.rb")
  end

  it "leaves out a spec that names nothing changed", :aggregate_failures do
    expect(mapping.specs).not_to include("spec/unrelated_spec.rb")
    expect(mapping.because["spec/agent_run_spec.rb"]).to start_with("AgentRun")
  end
end

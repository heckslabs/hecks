require "hecks"
require "hecks/tools/move_former_name"
require "tmpdir"

# The codemod moves `formerly_known_as "Old"` on an aggregate into the world's `stored_as`, and
# writes nothing when it is only rehearsed.
RSpec.describe Hecks::Tools::MoveFormerName do
  let(:root) { Dir.mktmpdir("move-former-name") }
  let(:bluebook) { File.join(root, "deliver", "deliver.bluebook") }
  let(:world) { File.join(root, "hecks.world") }

  before do
    FileUtils.mkdir_p(File.dirname(bluebook))
    File.write(bluebook, <<~BLUEBOOK)
      Hecks.bluebook "Hecks" do
        aggregate "Revision" do
          formerly_known_as "Commit"
          description "One recorded change."
        end

        aggregate "Workspace" do
          formerly_known_as "Checkout"
        end

        aggregate "Plain" do
          description "Never renamed."
        end
      end
    BLUEBOOK
    File.write(world, "Hecks.world \"Hecks\" do\n  realm \"Hecks\"\nend\n")
  end

  after { FileUtils.remove_entry(root) }

  def run_tool(*argv) = capture_stdout { described_class.main(argv, root: root) }

  def capture_stdout
    out = StringIO.new
    original = $stdout
    $stdout = out
    yield
    out.string
  ensure
    $stdout = original
  end

  it "names the world line it would add when rehearsed" do
    expect(run_tool("--dry-run")).to include('stored_as Revision: "commit", Workspace: "checkout"')
  end

  it "changes nothing when rehearsed" do
    run_tool("--dry-run")
    expect(File.read(bluebook)).to include('formerly_known_as "Commit"')
  end

  it "removes the bluebook words" do
    run_tool
    expect(File.read(bluebook)).not_to include("formerly_known_as")
  end

  it "keeps the rest of the bluebook" do
    run_tool
    expect(File.read(bluebook)).to include('description "One recorded change."')
  end

  it "adds one stored_as line to the domain's world" do
    run_tool
    expect(File.read(world)).to include('  stored_as Revision: "commit", Workspace: "checkout"')
  end

  it "creates a world beside the bluebook when the domain has none" do
    File.delete(world)
    run_tool
    expect(File.read(File.join(root, "deliver", "deliver.world"))).to include('Hecks.world "Hecks" do')
  end

  it "says so when nothing is left to move" do
    run_tool
    expect(run_tool).to include("no aggregate-level formerly_known_as found")
  end
end

require "spec_helper"
require "tmpdir"
require "stringio"
require "hecks/tools/agent_roles"

# The projection of `RoleFile` rows into role files, run against scratch rows and a scratch
# directory: the checkout's own `.claude/agents` is read and never written.
RSpec.describe Hecks::Tools::AgentRoles do
  let(:dir) { Dir.mktmpdir("agent_roles") }
  let(:row) do
    { role: "scout", description: "Looks ahead.", tools: "Read, Grep", model: "sonnet", purpose: "You scout.",
      steps: "1. **Look.** Go.", rules: "## Handoffs\n\nTell the planner.", handback: "What you found." }
  end
  let(:expected) do
    "---\nname: scout\ndescription: Looks ahead.\ntools: Read, Grep\nmodel: sonnet\n" \
      "# Generated from agents.bluebook, do not edit\n---\n\nYou scout.\n\n## How to work\n\n1. **Look.** Go.\n\n" \
      "## What you hand back\n\nWhat you found.\n\n## Handoffs\n\nTell the planner.\n"
  end

  after { FileUtils.remove_entry(dir) }

  def run_tool(*argv) = described_class.main(argv, rows: [row], out: dir)
  def scout = File.join(dir, "scout.md")

  def hushed
    err = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = err
  end

  def quietly(&)
    out = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = out
  end

  def written
    quietly { run_tool }
    File.read(scout)
  end

  def checked_after_edit
    quietly { run_tool }
    File.write(scout, "#{File.read(scout)}\nan edit\n")
    run_tool("--check")
  end

  it "renders a row as the expected file" do
    expect(written).to eq(expected)
  end

  it "opens with a rules section other than Handoffs, ahead of the steps" do
    text = Hecks::Tools::AgentRoles::Render.text(row.merge(rules: "## Limits\n\nStay put.\n\n#{row[:rules]}"))

    expect(text.index("## Limits")).to be_between(text.index("You scout."), text.index("## How to work"))
  end

  it "keeps the frontmatter as the first block" do
    expect(written).to start_with("---\nname: scout\n")
  end

  it "passes --check when the files match" do
    written

    expect(quietly { run_tool("--check") }).to eq(0)
  end

  it "answers 1 under --check for a file whose body was edited" do
    expect(quietly { checked_after_edit }).to eq(1)
  end

  it "names, under --check, a file whose body was edited" do
    expect { checked_after_edit }.to output(/out of date: scout\.md/).to_stderr
  end

  it "names, under --check, a file that is missing" do
    expect { run_tool("--check") }.to output(/out of date: scout\.md/).to_stderr
  end

  it "does not write under --check" do
    expect { hushed { run_tool("--check") } }.not_to(change { Dir.children(dir) })
  end

  describe "a file whose frontmatter holds a key the row cannot say" do
    before { File.write(scout, "---\nname: scout\nmcpServers:\n  - hecks:\n---\n\nbody\n") }

    it "is refused by name" do
      expect { run_tool }.to output(/refused scout\.md: frontmatter mcpServers/).to_stderr
    end

    it "is left as it was" do
      expect { hushed { run_tool } }.not_to(change { File.read(scout) })
    end
  end

  describe "the real role files" do
    let(:root) { InMemoryDomain::ROOT }
    let(:rows) { Hecks::Tools::AgentRoles::Rows.read(root) }

    def listing = Dir[File.join(root, ".claude/agents/*")].to_h { |path| [path, File.mtime(path)] }

    def rendered_halves(real)
      _, front, body = Hecks::Tools::AgentRoles::Render.text(real).split(/^---\n/, 3)
      [front, body]
    end

    it "render each row with its head in the frontmatter and its text in the body", :aggregate_failures do
      rows.each do |real|
        front, body = rendered_halves(real)

        expect(front).to include("name: #{real[:role]}\n", "description: #{real[:description]}\n")
        expect(body).to include(real[:purpose], real[:steps], real[:handback])
      end
    end

    it "leave out the architect, whose file holds frontmatter a row cannot say" do
      names = %w[coder orchestrator orchestrator-owner planner pruner release_manager reviewer]
      expect(rows.map { |real| real[:role] }).to match_array(names)
    end

    it "are read by --check and never written" do
      expect { hushed { described_class.main(["--check"], root: root) } }.not_to(change { listing })
    end
  end
end

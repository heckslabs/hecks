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
    before { File.write(scout, "---\nname: scout\nhooks:\n  - Stop:\n---\n\nbody\n") }

    it "is refused by name" do
      expect { run_tool }.to output(/refused scout\.md: frontmatter hooks/).to_stderr
    end

    it "is left as it was" do
      expect { hushed { run_tool } }.not_to(change { File.read(scout) })
    end
  end

  describe "the guarded-role list" do
    let(:list) { File.join(dir, "guarded_roles") }

    def run_list(*argv) = described_class.main(argv, rows: [row], out: dir, guarded: { path: list, roles: %w[scout scout] })

    it "writes each role with routing rows once, under the banner" do
      quietly { run_list }
      expect(File.read(list)).to eq("# Generated from agents.bluebook, do not edit\nscout\n")
    end

    it "answers 1 under --check when the list is missing" do
      quietly { run_tool }
      expect(hushed { run_list("--check") }).to eq(1)
    end

    it "names the six guarded roles of the checkout, the product owner among them" do
      guarded = Hecks::Tools::AgentRoles::Rows.guarded(InMemoryDomain::ROOT)
      expect(guarded).to eq(%w[orchestrator scrum-master coach planner product-owner architect])
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

    it "project every role, the architect too" do
      names = %w[architect coder orchestrator orchestrator-owner planner pruner reviewer scrum-master coach product-owner]
      expect(rows.map { |real| real[:role] }).to match_array(names)
    end

    it "give the architect the mcpServers block its RoleServer row says" do
      front, = rendered_halves(rows.find { |real| real[:role] == "architect" })
      expect(front).to include("mcpServers:\n  - hecks:\n      type: stdio\n      command: .claude/hecks-door/hecks-helper-door")
    end

    it "tell the coder to run the quick gate once its work is committed, then have CI check it", :aggregate_failures do
      steps = rows.find { |real| real[:role] == "coder" }[:steps]

      expect(steps.index("Commit on your branch")).to be < steps.index("gate_run.gate! stage=quick")
      expect(steps.index("gate_run.gate! stage=quick")).to be < steps.index("EarlyCi.request!")
    end

    it "hand a coder's red gate or red spec back as blocked, never as submitted" do
      handback = rows.find { |real| real[:role] == "coder" }[:handback]
      expect(handback).to include("the quick gate is green", "never reclassified")
    end

    it "are read by --check and never written" do
      expect { hushed { described_class.main(["--check"], root: root) } }.not_to(change { listing })
    end
  end
end

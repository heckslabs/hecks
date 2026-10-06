require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "hecks/tools"
require "hecks/tools/lanes"

# The branches are `Lane` rows of the Vocabulary chapter. `hecks regeneration_run.project_lanes` writes
# each guarded lane's ruleset and the workflow that promotes the lanes that follow another, and with
# `--live` compares (or, confirmed, updates) the rulesets GitHub holds. This spec holds the committed
# files to the rows and the comparison to the rows' own words.
RSpec.describe Hecks::Tools::Lanes do
  let(:root) { Hecks::Tools::ROOT }
  let(:github) { instance_spy(Hecks::Adapters::GithubRulesets) }

  def committed_ruleset = JSON.parse(File.read(File.join(root, ".github/rulesets/stable.json")))

  def promote_workflow = YAML.load_file(File.join(root, ".github/workflows/promote.yml"))

  describe "the committed files" do
    it "hold exactly what the Lane rows project" do
      drifted = described_class.projection(root).reject { |path, text| File.exist?(path) && File.read(path) == text }

      expect(drifted.keys).to be_empty, "have drifted from the Lane rows - run hecks regeneration_run.project_lanes"
    end

    it "leave no ruleset the rows no longer account for" do
      expect(described_class.leftover(root, described_class.projection(root))).to eq([])
    end

    it "let a guarded lane be neither deleted nor rewound, and name no actor that may bypass it",
       :aggregate_failures do
      stable = committed_ruleset

      expect(stable.dig("conditions", "ref_name", "include")).to eq(["refs/heads/stable"])
      expect(stable["rules"].map { |rule| rule["type"] })
        .to contain_exactly("deletion", "non_fast_forward", "required_status_checks")
      expect(stable["bypass_actors"]).to eq([])
    end

    it "let a green lane take only a commit that passed every RequiredCheck", :aggregate_failures do
      required = committed_ruleset["rules"].find { |rule| rule["type"] == "required_status_checks" }
      contexts = required.dig("parameters", "required_status_checks").map { |check| check["context"] }

      expect(contexts).to eq(Hecks::Vocabulary.rows("RequiredCheck").map { |check| check["name"] })
    end

    it "write no ruleset for a lane that takes pushes from anyone" do
      expect(File.exist?(File.join(root, ".github/rulesets/main.json"))).to be(false)
    end

    it "promote after CI on the lane a lane follows", :aggregate_failures do
      workflow = promote_workflow

      expect(workflow.fetch(true, workflow["on"]).dig("workflow_run", "branches")).to eq(["main"])
      expect(workflow.dig("jobs", "promote_stable", "steps").filter_map { |step| step["uses"] })
        .to eq(%w[actions/checkout@v4 ./.github/actions/setup-ruby ./.github/actions/hecks-environment])
    end

    it "name no rule of their own: the workflow runs the promote command" do
      run = promote_workflow.dig("jobs", "promote_stable", "steps").last.fetch("run")

      expect(run).to include("exe/hecks promotion_run.promote lane=stable", "--confirm")
    end
  end

  describe "main" do
    let(:work) { Dir.mktmpdir("lanes_root") }

    def ruleset_path = File.join(work, ".github/rulesets/stable.json")

    def main_in_work(*argv) = described_class.main(argv, root: work)

    before do
      described_class.projection(root).each_key do |path|
        FileUtils.mkdir_p(File.dirname(path.sub(root, work)))
        FileUtils.cp(path, path.sub(root, work))
      end
    end

    after { FileUtils.rm_rf(work) }

    it "answers 0 when every file is current", :aggregate_failures do
      expect { expect(main_in_work("--check")).to eq(0) }.to output(/every one current/).to_stdout
    end

    it "names a file edited by hand and writes nothing under --check", :aggregate_failures do
      File.write(ruleset_path, File.read(ruleset_path).sub('"active"', '"disabled"'))
      edited = File.read(ruleset_path)

      expect { expect(main_in_work("--check")).to eq(1) }.to output(%r{out of date: \.github/rulesets/stable\.json}).to_stderr
      expect(File.read(ruleset_path)).to eq(edited)
    end

    it "restores a file edited by hand", :aggregate_failures do
      File.write(ruleset_path, "{}")

      expect { main_in_work }.to output(%r{wrote \.github/rulesets/stable\.json}).to_stdout
      expect(File.read(ruleset_path)).to eq(described_class.projection(work).fetch(ruleset_path))
    end

    it "removes a ruleset no row accounts for", :aggregate_failures do
      retired = File.join(work, ".github/rulesets/retired.json")
      File.write(retired, "{}")

      expect { main_in_work }.to output(/retired\.json/).to_stdout
      expect(File.exist?(retired)).to be(false)
    end
  end

  describe "--live" do
    let(:projected) { described_class.ruleset(described_class.lanes.find { |lane| lane["name"] == "stable" }) }
    let(:missing) { ["lane-stable: GitHub has no such ruleset"] }

    def live(*argv) = described_class.main(["--live", *argv], rulesets: github)

    it "answers 0, and changes nothing, when GitHub holds the ruleset as projected", :aggregate_failures do
      allow(github).to receive_messages(named: projected, differences: [])

      expect { expect(live).to eq(0) }.to output(/holds every guarded lane's ruleset as projected/).to_stdout
      expect(github).not_to have_received(:apply)
    end

    it "names what differs and changes nothing without --confirm", :aggregate_failures do
      allow(github).to receive_messages(named: nil, differences: missing)

      expect { expect(live).to eq(1) }.to output(/GitHub has no such ruleset/).to_stdout.and output(/add --confirm/).to_stderr
      expect(github).not_to have_received(:apply)
    end

    it "makes GitHub match, and answers 0, with --confirm", :aggregate_failures do
      allow(github).to receive_messages(named: nil, differences: missing)
      allow(github).to receive(:apply).with(projected).and_return(:created)

      expect { expect(live("--confirm")).to eq(0) }.to output(/lane-stable: created/).to_stdout
    end
  end

  describe "a row the projection cannot express" do
    def base = { "name" => "x", "guarded" => "no", "pushers" => "anyone", "feeds" => "", "follows" => "" }

    def rows_are(**given)
      allow(Hecks::Vocabulary).to receive(:rows).with("Lane").and_return([base.merge(given.transform_keys(&:to_s))])
    end

    it "refuses a pusher it has no bypass for" do
      rows_are(guarded: "yes", pushers: "nobody")

      expect { described_class.lanes }.to raise_error(SystemExit).and output(/x has pushers "nobody"/).to_stderr
    end

    it "refuses a lane that follows a lane no row names" do
      rows_are(follows: "y")

      expect { described_class.lanes }.to raise_error(SystemExit).and output(/x follows "y"/).to_stderr
    end
  end
end

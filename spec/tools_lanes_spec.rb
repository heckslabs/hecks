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
  let(:github) { instance_double(Hecks::Adapters::GithubRulesets) }

  describe "the committed files" do
    it "hold exactly what the Lane rows project" do
      described_class.projection(root).each do |path, text|
        expect(File.exist?(path) && File.read(path)).to eq(text),
                                                        "#{path.delete_prefix("#{root}/")} has drifted from the Lane " \
                                                        "rows - run hecks regeneration_run.project_lanes"
      end
    end

    it "leave no ruleset the rows no longer account for" do
      expect(described_class.leftover(root, described_class.projection(root))).to eq([])
    end

    it "let nothing but the promotion app push to a guarded lane, and let it delete and rewind nothing" do
      stable = JSON.parse(File.read(File.join(root, ".github/rulesets/stable.json")))

      expect(stable.dig("conditions", "ref_name", "include")).to eq(["refs/heads/stable"])
      expect(stable["rules"].map { |rule| rule["type"] }).to contain_exactly("deletion", "non_fast_forward", "update")
      expect(stable["bypass_actors"]).to eq([{ "actor_id" => 15_368, "actor_type" => "Integration",
                                               "bypass_mode" => "always" }])
    end

    it "write no ruleset for a lane that takes pushes from anyone" do
      expect(File.exist?(File.join(root, ".github/rulesets/main.json"))).to be(false)
    end

    it "promote after CI on the lane a lane follows, naming no rule of their own" do
      workflow = YAML.load_file(File.join(root, ".github/workflows/promote.yml"))
      run = workflow.dig("jobs", "promote_stable", "steps").last.fetch("run")

      expect(workflow.fetch(true, workflow["on"]).dig("workflow_run", "branches")).to eq(["main"])
      expect(run).to include("exe/hecks promotion_run.promote lane=stable", "--confirm")
      expect(workflow.dig("jobs", "promote_stable", "steps").filter_map { |step| step["uses"] })
        .to eq(%w[actions/checkout@v4 ./.github/actions/setup-ruby ./.github/actions/hecks-environment])
    end
  end

  describe "main" do
    let(:work) { Dir.mktmpdir("lanes_root") }

    before do
      FileUtils.mkdir_p(File.join(work, ".github/rulesets"))
      FileUtils.mkdir_p(File.join(work, ".github/workflows"))
      described_class.projection(root).each_key do |path|
        FileUtils.mkdir_p(File.dirname(path.sub(root, work)))
        FileUtils.cp(path, path.sub(root, work))
      end
    end

    after { FileUtils.rm_rf(work) }

    it "answers 0 when every file is current" do
      expect { expect(described_class.main(["--check"], root: work)).to eq(0) }.to output(/every one current/).to_stdout
    end

    it "names a file edited by hand and writes nothing under --check" do
      path = File.join(work, ".github/rulesets/stable.json")
      File.write(path, File.read(path).sub('"always"', '"pull_request"'))
      before = File.read(path)

      expect { expect(described_class.main(["--check"], root: work)).to eq(1) }
        .to output(%r{out of date: \.github/rulesets/stable\.json}).to_stderr
      expect(File.read(path)).to eq(before)
    end

    it "restores a file edited by hand, and removes a ruleset no row accounts for" do
      path = File.join(work, ".github/rulesets/stable.json")
      File.write(path, "{}")
      File.write(File.join(work, ".github/rulesets/retired.json"), "{}")

      expect { described_class.main([], root: work) }.to output(%r{wrote \.github/rulesets/stable\.json}).to_stdout
      expect(File.read(path)).to eq(described_class.projection(work).fetch(path))
      expect(File.exist?(File.join(work, ".github/rulesets/retired.json"))).to be(false)
    end
  end

  describe "--live" do
    let(:projected) { described_class.ruleset(described_class.lanes.find { |lane| lane["name"] == "stable" }) }

    it "answers 0, and changes nothing, when GitHub holds the ruleset as projected" do
      allow(github).to receive_messages(named: projected, differences: [])
      expect(github).not_to receive(:apply)

      expect { expect(described_class.main(["--live"], rulesets: github)).to eq(0) }
        .to output(/holds every guarded lane's ruleset as projected/).to_stdout
    end

    it "names what differs and changes nothing without --confirm" do
      allow(github).to receive_messages(named: nil, differences: ["lane-stable: GitHub has no such ruleset"])
      expect(github).not_to receive(:apply)

      expect { expect(described_class.main(["--live"], rulesets: github)).to eq(1) }
        .to output(/GitHub has no such ruleset/).to_stdout.and output(/add --confirm/).to_stderr
    end

    it "makes GitHub match, and answers 0, with --confirm" do
      allow(github).to receive_messages(named: nil, differences: ["lane-stable: GitHub has no such ruleset"])
      allow(github).to receive(:apply).with(projected).and_return(:created)

      expect { expect(described_class.main(%w[--live --confirm], rulesets: github)).to eq(0) }
        .to output(/lane-stable: created/).to_stdout
    end
  end

  describe "a row the projection cannot express" do
    it "refuses a pusher it has no bypass for" do
      allow(Hecks::Vocabulary).to receive(:rows).with("Lane")
                                                .and_return([{ "name" => "x", "guarded" => "yes", "pushers" => "nobody",
"feeds" => "", "follows" => "" }])

      expect { described_class.lanes }.to raise_error(SystemExit).and output(/x has pushers "nobody"/).to_stderr
    end

    it "refuses a lane that follows a lane no row names" do
      allow(Hecks::Vocabulary).to receive(:rows).with("Lane")
                                                .and_return([{ "name" => "x", "guarded" => "no", "pushers" => "anyone",
"feeds" => "", "follows" => "y" }])

      expect { described_class.lanes }.to raise_error(SystemExit).and output(/x follows "y"/).to_stderr
    end
  end
end

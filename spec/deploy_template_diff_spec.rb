require "open3"
require "json"
require "hecks/projections/deploy/template_diff"

# `bin/deploy_template_diff` and `Hecks::Projections::Deploy::TemplateDiff`: the offline half of
# checking that a generated template leaves a deployed stack untouched. The fixtures are small
# neutral templates; `same_written_differently.yaml` is `base.yaml` with its keys reordered, its
# short forms written long, and its comments dropped.
RSpec.describe Hecks::Projections::Deploy::TemplateDiff do
  let(:fixtures) { File.expand_path("fixtures/deploy_template_diff", __dir__) }
  let(:base) { File.join(fixtures, "base.yaml") }
  let(:rewritten) { File.join(fixtures, "same_written_differently.yaml") }
  let(:edited) { File.join(fixtures, "edited.yaml") }

  def sections(report) = report.sections

  describe "loading" do
    it "reads short-form intrinsics as the long forms they stand for" do
      template = described_class::Loader.load(<<~YAML)
        Resources:
          A:
            Properties:
              One: !Ref Thing
              Two: !GetAtt Thing.Arn
              Three: !Sub "${Thing}-x"
              Four: !Join ["-", [a, b]]
      YAML

      expect(template["Resources"]["A"]["Properties"]).to eq(
        "One" => { "Ref" => "Thing" }, "Two" => { "Fn::GetAtt" => %w[Thing Arn] },
        "Three" => { "Fn::Sub" => "${Thing}-x" }, "Four" => { "Fn::Join" => ["-", %w[a b]] }
      )
    end

    it "types plain scalars as YAML does and leaves quoted ones as text" do
      template = described_class::Loader.load("Resources:\n  A:\n    Properties: { N: 8080, S: \"8080\", B: true }\n")

      expect(template["Resources"]["A"]["Properties"]).to eq("N" => 8080, "S" => "8080", "B" => true)
    end

    it "refuses text that is not a mapping, is not YAML, or uses an alias" do
      expect { described_class::Loader.load("- a\n- b\n") }.to raise_error(ArgumentError, /mapping at the top level/)
      expect { described_class::Loader.load("a: [\n") }.to raise_error(ArgumentError, /not valid YAML/)
      expect { described_class::Loader.load("a: &x 1\nb: *x\n") }.to raise_error(ArgumentError, /aliases/)
      expect { described_class::Loader.load("") }.to raise_error(ArgumentError, /empty/)
    end
  end

  describe "two templates that say the same thing" do
    it "reports no difference across reordered keys, dropped comments and long-form intrinsics" do
      report = described_class.diff_files(base, rewritten)

      expect(report.different?).to be(false)
      expect(described_class.render(report)).to eq("no differences\n")
    end
  end

  describe "two templates that differ" do
    subject(:report) { described_class.diff_files(base, edited) }

    it "lists added, removed and changed resources by logical id" do
      resources = sections(report)["Resources"]

      expect(resources.added).to eq([["Topic", "AWS::SNS::Topic"]])
      expect(resources.changed.map(&:name)).to eq(%w[Distribution Repo Task])
    end

    it "lists parameters and outputs the same way" do
      parameters = sections(report)["Parameters"]
      outputs = sections(report)["Outputs"]

      expect([parameters.added, parameters.removed]).to eq([[["NewParameter", "Number"]], [["OldParameter", "String"]]])
      expect([outputs.added, outputs.removed].map { |list| list.map(&:first) }).to eq([["TopicArn"], ["BucketName"]])
      expect(outputs.changed.first.changes.first.path).to eq("Value.Fn::GetAtt[1]")
    end

    it "names each changed property, matching list entries by name rather than position" do
      task = sections(report)["Resources"].changed.find { |entity| entity.name == "Task" }
      paths = task.changes.map { |change| [change.path, change.kind] }

      expect(paths).to include(
        ["Properties.ContainerDefinitions[Name=web].Environment[Name=TOPIC_ARN]", :added],
        ["Properties.ContainerDefinitions[Name=worker]", :added],
        ["Properties.Memory", :changed]
      )
    end

    it "marks a changed resource type as a replacement" do
      repo = sections(report)["Resources"].changed.find { |entity| entity.name == "Repo" }

      expect(repo.replaced).to be(true)
    end

    it "reports a changed cache behavior order, which CloudFront reads first-match-wins" do
      distribution = sections(report)["Resources"].changed.find { |entity| entity.name == "Distribution" }

      expect(distribution.changes.map(&:kind)).to eq([:reordered])
    end

    it "marks a number against the same digits as text as cosmetic" do
      task = sections(report)["Resources"].changed.find { |entity| entity.name == "Task" }

      expect(task.changes.find { |change| change.path == "Properties.Cpu" }.cosmetic).to be(true)
    end

    it "compares the other top-level keys as values" do
      expect(sections(report)["Template"].map(&:path)).to eq(["Description"])
    end
  end

  describe "cosmetic differences" do
    let(:number) { "Resources:\n  A:\n    Type: T\n    Properties:\n      Cpu: 256\n" }
    let(:text) { "Resources:\n  A:\n    Type: T\n    Properties:\n      Cpu: \"256\"\n" }

    it "do not count unless strict" do
      expect(described_class.diff(number, text).different?).to be(false)
      expect(described_class.diff(number, text, strict: true).different?).to be(true)
      expect(described_class.render(described_class.diff(number, text))).to include("only cosmetic differences")
    end
  end

  describe "normalization" do
    def differ?(before, after)
      described_class.diff("Resources:\n  A:\n    Properties:\n      P: #{before}\n",
                           "Resources:\n  A:\n    Properties:\n      P: #{after}\n").different?
    end

    it "treats a Sub of one variable as the Ref or GetAtt it is" do
      expect(differ?('!Sub "${Thing}"', "!Ref Thing")).to be(false)
      expect(differ?('!Sub "${Thing.Arn}"', "!GetAtt Thing.Arn")).to be(false)
      expect(differ?('!Sub "${AWS::Region}"', "!Ref AWS::Region")).to be(false)
      expect(differ?('!Sub "${Thing}-x"', "!Ref Thing")).to be(true)
    end

    it "ignores the order of DependsOn" do
      first = "Resources:\n  A:\n    DependsOn: [B, C]\n"
      second = "Resources:\n  A:\n    DependsOn: [C, B]\n"

      expect(described_class.diff(first, second).different?).to be(false)
    end
  end

  describe "the command" do
    def run(*args)
      Open3.capture3("ruby", File.expand_path("../bin/deploy_template_diff", __dir__), *args)
    end

    it "exits 0 for templates that do not differ" do
      out, _err, status = run(base, rewritten)

      expect([status.exitstatus, out]).to eq([0, "no differences\n"])
    end

    it "exits 1 and lists the differences for templates that do" do
      out, _err, status = run(base, edited)

      expect(status.exitstatus).to eq(1)
      expect(out).to include("+ Topic (AWS::SNS::Topic)", "REPLACEMENT")
    end

    it "writes JSON with --json" do
      out, _err, status = run(base, edited, "--json")
      parsed = JSON.parse(out)

      expect(status.exitstatus).to eq(1)
      expect(parsed["different"]).to be(true)
      expect(parsed["sections"]["Resources"]["added"]).to eq([{ "id" => "Topic", "type" => "AWS::SNS::Topic" }])
    end

    it "exits 2 with a message for a missing file" do
      _out, err, status = run(base, File.join(fixtures, "missing.yaml"))

      expect([status.exitstatus, err]).to match([2, /missing\.yaml does not exist/])
    end
  end
end

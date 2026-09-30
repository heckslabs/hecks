require "spec_helper"
require "tmpdir"
require_relative "../../support/fake_codebase_shell"
require_relative "../../../lib/hecks/hecks/adapters/deploy_toolchain"

# The DeployToolchain port's adapter asks the scripts that generate a recipe, lint it and project
# the OIDC manifests, and compares two templates itself. A fake shell stands in for every child, so
# what is asked of the tools is tested without running one.
RSpec.describe Hecks::Adapters::DeployToolchain do
  let(:adapter) { described_class.new }

  after do
    described_class.shell = nil
    Hecks::Adapters::Codebase::Tree.root = nil
  end

  def shell_answering(*answers)
    described_class.shell = FakeCodebaseShell.new(*answers)
  end

  describe "#generate" do
    it "runs bin/project_deploy with the flags the record holds, and the domain last" do
      shell = shell_answering("wrote deploy/shop/template.yaml\n")

      answer = adapter.generate(domain: { value: "shop" }, tenant: { value: "acme" }, schema: nil,
                                out: { value: "/tmp/out" }, environment: nil)

      expect(answer).to eq(output: { value: "wrote deploy/shop/template.yaml\n" })
      expect(shell.asked.first[:program]).to eq(RbConfig.ruby)
      expect(shell.command.first).to end_with("bin/project_deploy")
      expect(shell.command.drop(1)).to eq(%w[--tenant=acme --out=/tmp/out shop])
      expect(shell.env).to eq("HECKS_NO_3_0_NOTICE" => "1")
    end

    it "refuses with what the generator printed when it ends non-zero" do
      shell_answering(["no deployed_to block", 1])

      expect { adapter.generate(domain: { value: "shop" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "no deployed_to block")
    end

    it "refuses outside a hecks checkout without starting anything" do
      shell = shell_answering
      Dir.mktmpdir("not_a_checkout") do |dir|
        Hecks::Adapters::Codebase::Tree.root = dir

        expect { adapter.generate(domain: { value: "shop" }) }
          .to raise_error(Hecks::Adapters::Codebase::Tree::NeedsCheckout, /needs a hecks checkout/)
      end
      expect(shell.asked).to be_empty
    end
  end

  describe "#scan" do
    it "runs bin/lint_deploy_recipes on each Makefile named" do
      shell = shell_answering("no violations found.\n")

      answer = adapter.scan(makefiles: { value: "a/Makefile, b/Makefile" })

      expect(answer).to eq(report: { value: "no violations found.\n" })
      expect(shell.command.first).to end_with("bin/lint_deploy_recipes")
      expect(shell.command.drop(1)).to eq(%w[a/Makefile b/Makefile])
    end

    it "lints the generated fixture domains when no Makefile is named" do
      shell = shell_answering("no violations found.\n")

      adapter.scan(makefiles: nil)

      expect(shell.command.drop(1)).to eq([])
    end

    it "refuses with the linter's report when it finds a violation" do
      shell_answering(["1 violation(s) found", 1])

      expect { adapter.scan(makefiles: { value: "a/Makefile" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "1 violation(s) found")
    end
  end

  describe "#manifest" do
    it "runs bin/project_oidc on each domain named" do
      shell = shell_answering("  examples/banking/oidc.json  <-  Banking\n")

      answer = adapter.manifest(domains: { value: "examples/banking,examples/pizzas" })

      expect(answer.dig(:output, :value)).to include("Banking")
      expect(shell.command.first).to end_with("bin/project_oidc")
      expect(shell.command.drop(1)).to eq(%w[examples/banking examples/pizzas])
    end
  end

  describe "#compare" do
    def templates(dir, after_body)
      File.write(File.join(dir, "a.yaml"), "Resources:\n  Bucket:\n    Type: AWS::S3::Bucket\n")
      File.write(File.join(dir, "b.yaml"), after_body)
      [{ value: File.join(dir, "a.yaml") }, { value: File.join(dir, "b.yaml") }]
    end

    it "answers whether the templates differ, and the report, without starting a child" do
      shell = shell_answering
      Dir.mktmpdir("compare") do |dir|
        before, after = templates(dir, "Resources:\n  Bucket:\n    Type: AWS::S3::Bucket\n    Properties:\n      BucketName: x\n")

        answer = adapter.compare(before: before, after: after)

        expect(answer.dig(:different, :value)).to be(true)
        expect(answer.dig(:report, :value)).to include("~ Bucket (AWS::S3::Bucket)")
      end
      expect(shell.asked).to be_empty
    end

    it "does not count a cosmetic difference unless strict" do
      Dir.mktmpdir("compare") do |dir|
        File.write(File.join(dir, "a.yaml"), "Resources:\n  A:\n    Type: T\n    Properties:\n      Cpu: 256\n")
        File.write(File.join(dir, "b.yaml"), "Resources:\n  A:\n    Type: T\n    Properties:\n      Cpu: \"256\"\n")
        before = { value: File.join(dir, "a.yaml") }
        after  = { value: File.join(dir, "b.yaml") }

        expect(adapter.compare(before: before, after: after).dig(:different, :value)).to be(false)
        expect(adapter.compare(before: before, after: after, strict: { value: true }).dig(:different, :value)).to be(true)
      end
    end

    it "renders the report as JSON when asked" do
      Dir.mktmpdir("compare") do |dir|
        before, after = templates(dir, "Resources:\n  Bucket:\n    Type: AWS::S3::Bucket\n")

        text = adapter.compare(before: before, after: after, json: { value: true }).dig(:report, :value)

        expect(JSON.parse(text)).to include("different" => false)
      end
    end

    it "refuses a template that is not there" do
      expect { adapter.compare(before: { value: "/no/such/a.yaml" }, after: { value: "/no/such/b.yaml" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /does not exist/)
    end
  end
end

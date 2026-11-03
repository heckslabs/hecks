require "spec_helper"
require "open3"
require "hecks/quality_control/adapters/image_roll"

# The RollImages chain's classifier and roll adapter. The change set, the quick gate's records
# and the docker and make commands are all stubbed: no image is built, nothing is rolled, and no
# AWS or database is touched.
RSpec.describe Hecks::Adapters::ImageRoll do
  # Answers the quick gate's records for the QA ledger, as `query` reads them.
  class GateLedgerStub
    def initialize(rows)
      @rows = rows
    end

    def query(_name) = @rows
  end

  let(:sha) { "b" * 40 }
  let(:platform) { "heckslabs/embryonaut_platform" }
  let(:rows) { [{ reference: { value: sha }, verdict: { value: "green" } }] }
  let(:commands) { class_double(described_class::Commands) }

  def classifier = described_class.new(ledger: GateLedgerStub.new(rows), commands: commands)

  def changed_files(*paths)
    allow(Open3).to receive(:capture2e).and_return([paths.join("\n"), instance_double(Process::Status, success?: true)])
  end

  def classify(branch: "main", **)
    classifier.classify(commit: sha, branch: branch, repo: platform, **)
  end

  describe ".image_path?" do
    it "admits the console container's inputs", :aggregate_failures do
      expect(%w[deploy/console/config.ru vendor/embryonaut_console/web/app.rb Dockerfile]
        .map { |path| described_class.image_path?(path) }).to all(be true)
    end

    it "refuses infrastructure, translation edges and near-miss names", :aggregate_failures do
      expect(%w[deploy-aws/box-generated/Makefile deploy/quality-control-webhook/template.yaml
                bluebook/translations/2-x.bluebook deploy/console_settings.json]
        .map { |path| described_class.image_path?(path) }).to all(be false)
    end
  end

  describe "#classify" do
    it "answers image for a change to the console inputs only", :aggregate_failures do
      changed_files("deploy/console/health.rb", "vendor/embryonaut_console/web/app.rb")

      expect(classify).to include(kind: { value: "image" }, app: { value: "console" })
    end

    it "answers infra when any path is outside the container, naming the paths" do
      changed_files("deploy/console/health.rb", "deploy-aws/box-generated/Makefile")

      expect(classify).to include(kind: { value: "infra" }, paths: { value: include("deploy-aws/box-generated/Makefile") })
    end

    it "classifies an image-only commit without a MainCheck on record", :aggregate_failures do
      changed_files("deploy/console/health.rb")
      rows.clear

      expect(classify).to include(kind: { value: "image" })
      expect(Open3).to have_received(:capture2e).once
    end

    it "classifies an infra commit as infra even with no MainCheck on record" do
      changed_files("deploy-aws/box-generated/Makefile")
      rows.clear

      expect(classify).to include(kind: { value: "infra" })
    end

    it "refuses a branch other than main" do
      expect { classify(branch: "feature") }.to raise_error(described_class::Refused, /only main rolls/)
    end
  end

  describe "#roll" do
    before { changed_files("deploy/console/health.rb") }

    it "builds the console image, then rolls it, and answers done" do
      allow(commands).to receive_messages(docker_build: ["built", true], deploy_service: ["rolled", true])

      expect(classifier.roll(commit: sha, app: "console")).to include(status: { value: "done" })
    end

    it "rolls an image-only commit with no MainCheck on record" do
      allow(commands).to receive_messages(docker_build: ["built", true], deploy_service: ["rolled", true])
      rows.clear

      expect(classifier.roll(commit: sha, app: "console")).to include(status: { value: "done" })
    end

    it "refuses an infra roll whose quick gate on record is not green" do
      changed_files("deploy-aws/box-generated/Makefile")
      rows.clear

      expect { classifier.roll(commit: sha, app: "console") }.to raise_error(described_class::Refused, /not green/)
    end

    it "rolls an infra commit whose quick gate on record is green" do
      changed_files("deploy-aws/box-generated/Makefile")
      allow(commands).to receive_messages(docker_build: ["built", true], deploy_service: ["rolled", true])

      expect(classifier.roll(commit: sha, app: "console")).to include(status: { value: "done" })
    end

    it "answers failed when the roll exits non-zero" do
      allow(commands).to receive_messages(docker_build: ["built", true], deploy_service: ["smoke failed", false])

      expect(classifier.roll(commit: sha, app: "console")).to include(status: { value: "failed" })
    end

    it "refuses, and never rolls, when the image does not build" do
      allow(commands).to receive(:docker_build).and_return(["no daemon", false])

      expect { classifier.roll(commit: sha, app: "console") }.to raise_error(described_class::Refused, /did not build/)
    end
  end
end

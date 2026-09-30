require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../../lib/hecks/hecks/adapters/local_files"

# The Workspace port's adapter does the Deploy chapter's file work: it surveys a domain's declared
# deploy target, renders the recipe, writes OIDC manifests and compares two templates (ADR 0080,
# section 7). Arguments arrive the way the runtime hands them, value objects as `{ value: x }`.
RSpec.describe Hecks::Adapters::DeployFiles do
  DEPLOY_FILES_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Stall" do
      aggregate "Thing" do
        identified_by :name
        attribute :name, ThingName
        value_object "ThingName" do
          attribute :value, String
          invariant("named") { !value.to_s.empty? }
        end
        command "Create" do
          attribute :name, ThingName
          sets :name
          emits "ThingCreated"
        end
      end
    end
  RUBY

  subject(:files) { Hecks::Adapters::LocalFiles.new }

  around do |example|
    Dir.mktmpdir("deploy_files") do |dir|
      @dir = dir
      write("stall/bluebook/stall.bluebook", DEPLOY_FILES_BLUEBOOK)
      write("stall/bluebook/stall.hecksagon", %(Hecks.hecksagon "Stall" do\n  persisted_by "Memory"\nend\n))
      write("stall/bluebook/stall.world",
            %(Hecks.world "Stall" do\n  deployed_to("AwsFargate") do\n    region "eu-west-1"\n  end\nend\n))
      Dir.chdir(dir) { example.run }
    end
  end

  def write(path, text)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def value(text) = { value: text }

  describe "#survey" do
    it "reports the adapter the domain's world declares" do
      expect(files.survey(domain: value("stall"))).to eq(target: value("AwsFargate"))
    end

    it "reports an empty target for a world that declares none" do
      write("plain/bluebook/plain.world", %(Hecks.world "Plain" do\n  realm "Plain"\nend\n))

      expect(files.survey(domain: value("plain"))).to eq(target: value(""))
    end

    it "refuses a domain with no world file" do
      expect { files.survey(domain: value("nowhere")) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /nowhere.world does not exist/)
    end

    it "refuses an overlay that is not there" do
      expect { files.survey(domain: value("stall"), environment: value("staging")) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /staging.world does not exist/)
    end
  end

  describe "#render" do
    it "writes the recipe under deploy/<stack> of the project it runs in, one line per file" do
      report = files.render(domain: value("stall"))

      lines = report.dig(:report, :value).lines.map(&:chomp)
      expect(lines.first).to start_with("wrote ")
      expect(File.exist?(File.join(@dir, "deploy/stall/Makefile"))).to be true
      expect(File.read(File.join(@dir, "deploy/stall/template.yaml"))).to include("Stall")
    end

    it "writes where it is told, and names a tenant's stack apart" do
      files.render(domain: value("stall"), tenant: value("acme"), out: value(File.join(@dir, "elsewhere")))

      expect(File.read(File.join(@dir, "elsewhere/template.yaml"))).to include("stall-acme")
      expect(Dir.exist?(File.join(@dir, "deploy"))).to be false
    end

    it "refuses a schema with no tenant" do
      expect { files.render(domain: value("stall"), schema: value("acme")) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /--schema needs --tenant/)
    end

    it "refuses a world that names no deploy target, saying how to declare one" do
      write("plain/bluebook/plain.bluebook", DEPLOY_FILES_BLUEBOOK.sub('"Stall"', '"Plain"'))
      write("plain/bluebook/plain.world", %(Hecks.world "Plain" do\n  realm "Plain"\nend\n))

      expect { files.render(domain: value("plain")) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /declares no deployed_to/)
    end
  end

  describe "#write_manifests" do
    it "writes an oidc.json beside each domain named, and says which chapter it came from" do
      report = files.write_manifests(domains: value("stall"))

      expect(report.dig(:report, :value)).to eq("stall/oidc.json  <-  Stall")
      expect(JSON.parse(File.read(File.join(@dir, "stall/oidc.json")))).to be_a(Hash)
    end

    it "finds every domain under the project when none is named" do
      files.write_manifests(domains: nil)

      expect(File.exist?(File.join(@dir, "stall/oidc.json"))).to be true
    end

    it "refuses when nothing could be written" do
      expect { files.write_manifests(domains: value("nowhere")) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /nowhere/)
    end
  end

  describe "#diff" do
    before do
      write("a.yaml", "Resources:\n  Fn:\n    Type: AWS::Lambda::Function\n    Properties:\n      MemorySize: 128\n")
      write("b.yaml", "Resources:\n  Fn:\n    Type: AWS::Lambda::Function\n    Properties:\n      MemorySize: 256\n")
    end

    it "answers the report as text" do
      expect(files.diff(before: value("a.yaml"), after: value("b.yaml"))).to include("MemorySize")
    end

    it "answers the report as JSON, and says nothing differs for a template against itself" do
      different = JSON.parse(files.diff(before: value("a.yaml"), after: value("b.yaml"), json: value(true)))
      same = JSON.parse(files.diff(before: value("a.yaml"), after: value("a.yaml"), json: value(true), strict: value(true)))

      expect(different.fetch("different")).to be true
      expect(same.fetch("different")).to be false
    end

    it "refuses a template that is not there, as a refusal the launcher words" do
      expect { files.diff(before: value("a.yaml"), after: value("gone.yaml")) }
        .to raise_error(Hecks::Runtime::NotFound, /gone.yaml/)
    end
  end
end

require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../support/registry_repo"
require_relative "../../../lib/hecks/hecks/adapters/git"

# The Git port's adapter: `git` under a clean environment, and the vendoring of one registry
# package through it.
RSpec.describe Hecks::Adapters::Git, :io do
  let(:adapter) { described_class.new }
  let(:scratch) { Dir.mktmpdir("hecks-git-adapter") }
  let(:repo) { RegistryRepo.new(File.join(scratch, "registry")) }
  let(:root) { File.join(scratch, "project") }

  after { FileUtils.remove_entry(scratch) }

  def release(version)
    repo.write(
      "widgets/bluebook.yml"              => "name: widgets\nversion: #{version}\nsummary: Widgets.\n",
      "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook
    )
    repo.commit("widgets #{version}")
    repo.tag("widgets-v#{version}")
  end

  it "runs git in a directory and answers what it said" do
    release("1.0.0")

    result = adapter.capture("tag", "--list", chdir: repo.path)

    expect(result).to be_ok
    expect(result.out).to eq("widgets-v1.0.0\n")
  end

  it "is not redirected by an inherited GIT_DIR" do
    release("1.0.0")
    saved = ENV.fetch("GIT_DIR", nil)
    ENV["GIT_DIR"] = File.join(scratch, "elsewhere")

    expect(adapter.capture("rev-parse", "--git-dir", chdir: repo.path)).to be_ok
  ensure
    saved ? ENV["GIT_DIR"] = saved : ENV.delete("GIT_DIR")
  end

  describe "#pin" do
    it "vendors a release and reports what it pinned" do
      release("1.2.0")

      answer = adapter.pin(package: { value: "widgets@1.2.0" }, from: { value: repo.path }, root: { value: root })

      expect(answer.dig(:report, :value)).to include("Vendored embryonaut_bluebooks/widgets 1.2.0")
      expect(File.exist?(File.join(root, "vendor/embryonaut_bluebooks/widgets/bluebook/widgets.bluebook"))).to be(true)
    end

    it "takes the newest release when the package names no version" do
      release("1.0.0")
      release("1.1.0")

      answer = adapter.pin(package: { value: "widgets" }, from: { value: repo.path }, root: { value: root })

      expect(answer.dig(:report, :value)).to include("widgets 1.1.0")
    end

    it "reads the source from EMBRYONAUT_BLUEBOOKS_SRC when the record names none" do
      release("1.0.0")
      stub_const("ENV", ENV.to_h.merge("EMBRYONAUT_BLUEBOOKS_SRC" => repo.path))

      answer = adapter.pin(package: { value: "widgets" }, root: { value: root })

      expect(answer.dig(:report, :value)).to include("from #{repo.path}")
    end

    it "refuses a release the registry does not have, with the vendoring's own sentence" do
      release("1.0.0")

      expect { adapter.pin(package: { value: "widgets@9.9.9" }, from: { value: repo.path }, root: { value: root }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /9\.9\.9/)
    end

    it "refuses a source that is a directory but not a repository" do
      FileUtils.mkdir_p(File.join(scratch, "plain"))

      expect { adapter.pin(package: { value: "widgets" }, from: { value: File.join(scratch, "plain") }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /is not a git repository/)
    end

    it "refuses when there is no source to vendor from" do
      stub_const("ENV", ENV.to_h.merge("EMBRYONAUT_BLUEBOOKS_SRC" => nil))

      expect { adapter.pin(package: { value: "widgets" }, root: { value: root }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /usage/)
    end
  end

  describe "#verify" do
    it "answers the manifest of the vendored packages, with the project's own commit" do
      release("1.2.0")
      adapter.pin(package: { value: "widgets@1.2.0" }, from: { value: repo.path }, root: { value: root })
      project = RegistryRepo.new(root)
      project.commit("vendored")

      manifest = JSON.parse(adapter.verify(root: { value: root }).fetch(:text))

      expect(manifest.dig("built_from", "commit")).to eq(project.git("rev-parse", "HEAD").strip)
      expect(manifest.dig("built_from", "dirty")).to be(false)
      expect(manifest.dig("bluebooks", "widgets", "tag")).to eq("widgets-v1.2.0")
    end

    it "says the tree is dirty and the commit unknown outside a repository" do
      release("1.0.0")
      adapter.pin(package: { value: "widgets@1.0.0" }, from: { value: repo.path }, root: { value: root })

      manifest = JSON.parse(adapter.verify(root: { value: root }).fetch(:text))

      expect(manifest.fetch("built_from")).to eq("commit" => "unknown", "dirty" => false)
    end

    it "refuses with each disagreement" do
      release("1.0.0")
      adapter.pin(package: { value: "widgets@1.0.0" }, from: { value: repo.path }, root: { value: root })
      File.write(File.join(root, "vendor/embryonaut_bluebooks/widgets/bluebook/widgets.bluebook"), "#\n", mode: "a")

      expect { adapter.verify(root: { value: root }) }
        .to raise_error(Hecks::Runtime::NotFound, /FAIL widgets: vendored files hash to/)
    end

    it "refuses a project directory that is not there" do
      expect { adapter.verify(root: { value: File.join(scratch, "nowhere") }) }
        .to raise_error(Hecks::Runtime::NotFound, /is not a directory/)
    end
  end

  describe "#check and #tag" do
    before do
      repo.git("config", "user.name", "Spec")
      repo.git("config", "user.email", "spec@example.com")
      repo.write("widgets/CHANGELOG.md" => "## 1.0.0\n\nFirst.\n")
      release("1.0.0")
    end

    it "tags what the registry's rules allow, and says how to publish it" do
      repo.write("widgets/CHANGELOG.md"              => "## 1.1.0\n\nMore.\n\n## 1.0.0\n\nFirst.\n",
                 "widgets/bluebook.yml"              => "name: widgets\nversion: 1.1.0\nsummary: Widgets.\n",
                 "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook(extra_attribute: true))
      repo.commit("widgets 1.1.0")

      answer = adapter.tag(package: { value: "widgets" }, root: { value: repo.path })

      expect(answer.dig(:report, :value)).to end_with("git push origin widgets-v1.1.0")
      expect(adapter.check(root: { value: repo.path }).fetch(:text)).to eq("versions ok")
    end

    it "refuses a tag with the registry's own sentence" do
      expect { adapter.tag(package: { value: "widgets" }, root: { value: repo.path }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "widgets-v1.0.0 already exists")
    end

    it "refuses a check naming each package at fault, and a directory that is no repository" do
      repo.write("widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook(description: "Reworded."))
      repo.commit("reworded")

      expect { adapter.check(root: { value: repo.path }) }
        .to raise_error(Hecks::Runtime::NotFound, /\AFAIL widgets: bluebook files changed since widgets-v1.0.0/)
      expect { adapter.check(root: { value: scratch }) }.to raise_error(Hecks::Runtime::NotFound, /not a git repository/)
    end
  end
end

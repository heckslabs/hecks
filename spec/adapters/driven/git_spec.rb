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
end

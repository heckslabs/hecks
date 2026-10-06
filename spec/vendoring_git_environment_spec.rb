require "tmpdir"
require_relative "support/registry_repo"

# Git exports GIT_DIR, GIT_INDEX_FILE and their kin to the pre-push hook, and
# the hook's whole process tree inherits them. They outrank `git -C`, so a
# scratch repository the suite builds would otherwise be read from, and
# committed into, the repository that is pushing.
RSpec.describe Hecks::Vendoring::GitEnvironment do
  let(:scratch) { Dir.mktmpdir("hecks-git-environment-spec") }
  let(:decoy) { File.join(scratch, "decoy") }
  let(:poison) do
    {
      "GIT_DIR"        => File.join(decoy, ".git"),
      "GIT_WORK_TREE"  => decoy,
      "GIT_INDEX_FILE" => File.join(scratch, "no-such-index"),
      "GIT_PREFIX"     => "elsewhere/",
      "GIT_COMMON_DIR" => File.join(decoy, ".git")
    }
  end

  around do |example|
    saved = ENV.to_h.slice(*described_class::INHERITED)
    example.run
  ensure
    described_class::INHERITED.each { |name| ENV.delete(name) }
    saved.each { |name, value| ENV[name] = value }
  end

  before do
    FileUtils.mkdir_p(decoy)
    system("git", "init", "-q", "-b", "main", decoy, exception: true)
  end

  after { FileUtils.remove_entry(scratch) }

  def poisoned
    poison.each { |name, value| ENV[name] = value }
  end

  def decoy_commits
    Open3.capture3(described_class.clean, "git", "-C", decoy, "rev-list", "--all", "--count").first.strip
  end

  describe ".clean" do
    it "unsets every variable that pins git to a repository, and nothing else", :aggregate_failures do
      expect(described_class.clean.keys).to match_array(described_class::INHERITED)
      expect(described_class.clean.values.uniq).to eq([nil])
    end
  end

  describe ".scrub!" do
    it "removes them from this process's environment" do
      poisoned

      described_class.scrub!

      expect(ENV.to_h.keys & described_class::INHERITED).to be_empty
    end
  end

  describe "a scratch repository built while the hook's variables are inherited" do
    before { poisoned }

    it "commits into the scratch repository and never into the inherited one", :aggregate_failures do
      repo = RegistryRepo.new(File.join(scratch, "source"))
      repo.write("widgets/bluebook/widgets.bluebook" => "first\n")
      sha = repo.commit

      expect(sha).to match(/\A\h{40}\z/)
      expect(decoy_commits).to eq("0")
    end

    def pinned_two_files
      repo = RegistryRepo.new(File.join(scratch, "source"))
      repo.write("widgets/bluebook/widgets.bluebook" => "first\n", "widgets/bluebook/other.bluebook" => "other\n")
      repo.commit
      into = File.join(scratch, "project", "vendor", "widgets")
      result = Hecks::Vendoring.pin(from: repo.path, ref: "main", subtree: "widgets/bluebook", into: into, glob: "*.bluebook")
      [result, into]
    end

    it "pins and exports the scratch repository's files", :aggregate_failures do
      result, into = pinned_two_files

      expect(result.files).to eq(%w[other.bluebook widgets.bluebook])
      expect(Dir.children(File.join(into, "bluebook")).sort).to eq(%w[other.bluebook widgets.bluebook])
    end
  end
end

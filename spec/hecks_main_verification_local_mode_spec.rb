require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# What a landed commit is verified with, as the Tickets world's `main_verification` line says in
# `verifies`: `impacted` as before, `quick` the quick gate only, `off` nothing. The repository is a
# throwaway one on a local bare remote, the checks are a fake runner and the specs a stand-in.
RSpec.describe Hecks::Adapters::MainVerification, "#check and #bisect by local mode" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-local-mode")) }
  let(:ran) { [] }
  let(:asked) { [] }
  let(:searched) { [] }

  before do
    git("init", "-q", "--bare", "-b", "main", File.join(dir, "remote.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "remote.git"), repo, chdir: dir)
    git("checkout", "-q", "-B", "main")
    commit("README")
    git("push", "-q", "origin", "main")
    described_class.runner = method(:fake_run)
    described_class.impacted = method(:fake_impacted)
    described_class.specs = ->(*) { searched << :probe }
    described_class.log_directory = File.join(dir, "logs")
  end

  after do
    described_class.runner = nil
    described_class.impacted = nil
    described_class.specs = nil
    described_class.log_directory = nil
    FileUtils.remove_entry(dir)
  end

  def repo = File.join(dir, "repo")

  def marker = File.join(repo, ".git", "hecks-last-verified-main.json")

  def outcome_class = Hecks::Adapters::GitShallowCheck::ImpactedRun::Outcome

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(file)
    File.write(File.join(repo, file), file)
    git("add", ".")
    git("commit", "-q", "-m", file)
    git("rev-parse", "main")
  end

  def fake_run(argv, chdir:)
    ran << argv.last
    [true, chdir && ""]
  end

  def fake_impacted(changed, _since)
    asked << changed
    raise Hecks::Adapters::ConsoleCapture::Failure, "impacted specs red" if @red

    outcome_class.new(changed, [], 1, 1)
  end

  # Sets the world's `verifies` in the checkout the verification reads.
  def verifies(word)
    file = File.join(repo, Hecks::RustBuild::WorldRows::WORLD)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(File.join(repo, ".git", "info", "exclude"), "lib/\n")
    File.write(file, %(Hecks.world "Tickets" do\n  main_verification "MainVerification", workers: 2, verifies: "#{word}"\nend\n))
  end

  def shallow_off = Hecks::Adapters::GitShallowCheck::Switch.new(File.join(repo, ".git")).set("off")

  def verify(landed) = described_class.new.check(landed: landed, checkout: repo)

  def bisect(landed) = described_class.new.bisect(landed: landed, checkout: repo)

  def refusal(landed)
    @red = true
    verify(landed)
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  describe "impacted, with the shallow check off" do
    before { shallow_off && verifies("impacted") }

    it "runs the quick gate and the impacted specs", :aggregate_failures do
      verify(commit("a.txt"))
      expect(ran.size).to eq(1)
      expect(asked).to eq([["a.txt"]])
    end

    it "records the verified commit" do
      landed = commit("a.txt")
      verify(landed)
      expect(File.read(marker)).to include(landed)
    end

    it "searches a failure for its first bad merge", :aggregate_failures do
      expect(refusal(commit("a.txt"))).to include("no first bad merge")
      expect(bisect(commit("b.txt"))).to include(searched: { value: true })
    end
  end

  describe "quick, with the shallow check off" do
    before { shallow_off && verifies("quick") }

    it "runs the quick gate only", :aggregate_failures do
      verify(commit("a.txt"))
      expect(ran.size).to eq(1)
      expect(asked).to be_empty
    end

    it "writes no last-verified marker" do
      verify(commit("a.txt"))
      expect(File.exist?(marker)).to be(false)
    end

    it "makes no search and names none in a refusal", :aggregate_failures do
      ran.clear
      described_class.runner = ->(*) { [false, "red"] }
      expect { verify(commit("a.txt")) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /\A(?!.*first bad merge)/m)
      expect(searched).to be_empty
    end

    it "refuses the bisect, so no episode starts" do
      expect { bisect(commit("a.txt")) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "local verification is quick: no search is made")
    end
  end

  describe "off, with the shallow check off" do
    before { shallow_off && verifies("off") }

    it "runs no check of any kind", :aggregate_failures do
      verify(commit("a.txt"))
      expect(ran).to be_empty
      expect(asked).to be_empty
    end

    it "says nothing was verified here and writes no marker", :aggregate_failures do
      answer = verify(commit("a.txt"))
      expect(answer[:report][:value]).to include("local verification is off")
      expect(File.exist?(marker)).to be(false)
    end

    it "refuses the bisect, so no episode starts" do
      expect { bisect(commit("a.txt")) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "local verification is off: no search is made")
    end
  end

  describe "with the shallow check on" do
    before { verifies("off") }

    it "ignores the setting and runs the quick gate", :aggregate_failures do
      verify(commit("a.txt"))
      expect(ran.size).to eq(1)
      expect(asked).to be_empty
    end

    it "still writes the marker" do
      verify(commit("a.txt"))
      expect(File.exist?(marker)).to be(true)
    end

    it "answers a bisect with no search made, as before", :aggregate_failures do
      facts = bisect(commit("a.txt"))
      expect(facts[:searched]).to eq(value: false)
      expect(facts[:culprit]).to eq(value: "")
    end
  end

  it "reads a setting saved between two landings for the second one" do
    shallow_off && verifies("impacted")
    verify(commit("a.txt"))
    verifies("off")
    expect { verify(commit("b.txt")) }.not_to change(ran, :size)
  end

  it "stands at impacted when the world names no value" do
    shallow_off
    verify(commit("a.txt"))
    expect(asked).to eq([["a.txt"]])
  end
end

require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# A verification of a landed commit runs the quick gate, and, while the shallow check is off, the
# specs the landings since the last verified commit touch; a green one records the commit. The
# repository is a throwaway one on a local bare remote, the checks are a fake runner and the
# impacted-spec run is a stand-in.
RSpec.describe Hecks::Adapters::MainVerification, "#check with the shallow check off" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-main-impacted")) }
  let(:ran) { [] }
  let(:asked) { [] }
  let(:outcome_class) { Hecks::Adapters::GitShallowCheck::ImpactedRun::Outcome }
  let(:marker) { File.join(repo, ".git", "hecks-last-verified-main.json") }

  before do
    git("init", "-q", "--bare", "-b", "main", File.join(dir, "remote.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "remote.git"), repo, chdir: dir)
    git("checkout", "-q", "-B", "main")
    commit(repo, "README")
    git("push", "-q", "origin", "main")
    described_class.runner = method(:fake_run)
    described_class.impacted = method(:fake_impacted)
    described_class.log_directory = File.join(dir, "logs")
  end

  after do
    described_class.runner = nil
    described_class.impacted = nil
    described_class.log_directory = nil
    FileUtils.remove_entry(dir)
  end

  def repo = File.join(dir, "repo")

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(where, file)
    File.write(File.join(where, file), file)
    git("add", ".", chdir: where)
    git("commit", "-q", "-m", file, chdir: where)
  end

  def fake_run(argv, chdir:)
    ran << argv.last
    [true, chdir && ""]
  end

  def fake_impacted(changed, since)
    asked << [changed, since]
    raise Hecks::Adapters::ConsoleCapture::Failure, "impacted specs red: failing spec: spec/a_spec.rb" if @red

    outcome_class.new(changed, [], 1, 1)
  end

  def switch_off = Hecks::Adapters::GitShallowCheck::Switch.new(File.join(repo, ".git")).set("off")

  def landed_commit(file = "a.txt")
    commit(repo, file)
    git("rev-parse", "main")
  end

  def verify(landed) = described_class.new.check(landed: landed, checkout: repo)

  # Verifies a commit whose impacted spec is red, and answers the refusal.
  def verify_red(landed)
    @red = true
    verify(landed)
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e
  end

  def marked = JSON.parse(File.read(marker))

  describe "while the marker is absent" do
    it "runs only the quick gate", :aggregate_failures do
      verify(landed_commit)
      expect(ran.size).to eq(1)
      expect(asked).to be_empty
    end

    it "records the verified commit and the time", :aggregate_failures do
      landed = landed_commit
      verify(landed)
      expect(marked["sha"]).to eq(landed)
      expect(marked["at"]).to match(/\A\d{4}-\d\d-\d\dT/)
    end
  end

  describe "while the marker is off" do
    before { switch_off }

    it "runs the impacted specs of what the commit adds to origin/main when none was verified before" do
      verify(landed_commit)
      expect(asked).to eq([[["a.txt"], git("rev-parse", "origin/main")]])
    end

    # Verifies the first commit, lands two more and answers the newest, with the asks cleared.
    def verify_a_range_after(first)
      verify(first)
      landed_commit("b.txt")
      landed_commit("c.txt").tap { asked.clear }
    end

    it "runs the impacted specs of the range since the last verified commit" do
      first = landed_commit("a.txt")
      verify(verify_a_range_after(first))
      expect(asked).to eq([[%w[b.txt c.txt], first]])
    end

    it "names the impacted specs among the checks that passed" do
      expect(verify(landed_commit)[:report][:value]).to include("quick gate, impacted specs")
    end

    it "fails the verification on a red impacted spec, naming it", :aggregate_failures do
      refusal = verify_red(landed_commit)
      expect(refusal.message).to match(%r{failed verification: impacted specs.*spec/a_spec\.rb}m)
      expect(File.exist?(marker)).to be(false)
    end

    it "records the verified commit when the impacted specs are green" do
      landed = landed_commit
      verify(landed)
      expect(marked["sha"]).to eq(landed)
    end

    it "keeps the last marker when a verification fails" do
      first = landed_commit("a.txt")
      verify(first)
      verify_red(landed_commit("b.txt"))
      expect(marked["sha"]).to eq(first)
    end

    it "starts again from origin/main when the marker names a commit the new one does not descend from" do
      File.write(marker, JSON.generate("sha" => "f" * 40, "at" => Time.now.utc.iso8601))
      verify(landed_commit)
      expect(asked.map(&:last)).to eq([git("rev-parse", "origin/main")])
    end
  end
end

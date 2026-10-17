require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "hecks/tools"
require "hecks/tools/ci_gate_decision"

# The gate the workflow runs, over real git histories: a push whose `before` is the base.
RSpec.describe Hecks::Tools::CiGateDecision, ".touched? for the release_only gate" do
  let(:repo) { Dir.mktmpdir("release_only_gate") }

  before do
    git("init", "-q", "-b", "main")
    write("lib/hecks/version.rb", %(  VERSION = "3.10.0".freeze\n))
    write("lib/hecks/runtime.rb", "a\n")
    @base = commit("base")
  end

  after { FileUtils.rm_rf(repo) }

  def git(*args)
    out, status = Open3.capture2e("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?

    out.strip
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
    File.write(File.join(repo, path), text)
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD")
  end

  def touched?(green: true)
    allow(Hecks::Tools::ReleaseOnly).to receive(:check_runs).and_return(green ? every_check : [])
    event = File.join(repo, ".event.json")
    File.write(event, JSON.generate("before" => @base))
    env = { "GITHUB_EVENT_NAME" => "push", "GITHUB_EVENT_PATH" => event, "GITHUB_SHA" => git("rev-parse", "HEAD") }
    gate = Hecks::Tools::CiGates.gates.find { |row| row["name"] == "release_only" }
    described_class.touched?(gate, root: repo, env: env)
  end

  def every_check
    Hecks::Vocabulary.rows("RequiredCheck").map do |row|
      { "name" => row.fetch("name"), "conclusion" => "success", "started_at" => "2026-10-16T02:00:00Z" }
    end
  end

  it "inherits for a version bump on a certified base", :process do
    write("lib/hecks/version.rb", %(  VERSION = "3.11.0".freeze\n))
    commit("bump")
    expect(touched?).to be false
  end

  it "runs the suite when the base is not certified", :process do
    write("lib/hecks/version.rb", %(  VERSION = "3.11.0".freeze\n))
    commit("bump")
    expect(touched?(green: false)).to be true
  end

  it "runs the suite when the bump carries another file", :process do
    write("lib/hecks/version.rb", %(  VERSION = "3.11.0".freeze\n))
    write("lib/hecks/runtime.rb", "b\n")
    commit("bump and more")
    expect(touched?).to be true
  end
end

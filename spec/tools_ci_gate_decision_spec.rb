require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "hecks/tools"
require "hecks/tools/ci_gate_decision"

# `hecks decide_ci_gate gate=<name>` is what a gated job's detector runs. Nothing else pins what a
# gate answers, so this spec runs the decision against real git histories: the event as a runner
# gives it (an event file and environment variables), inside a checkout of a small history.
RSpec.describe Hecks::Tools::CiGateDecision do
  let(:repo) { Dir.mktmpdir("ci_gate_decision") }

  after { FileUtils.rm_rf(repo) }

  def git(*args)
    out, status = Open3.capture2e("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?

    out.strip
  end

  # Commits the paths on top of the current head and answers the new sha.
  def commit(*paths)
    paths.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
      File.write(File.join(repo, path), "#{path} #{rand}\n")
    end
    git("add", "-A")
    git("commit", "-m", paths.join(","))
    git("rev-parse", "HEAD")
  end

  # Runs the decision for a gate as a run of `event` and answers the `touched` it wrote and what it
  # said on stderr.
  def touched(gate, event:, payload: {})
    output = File.join(repo, ".github_output")
    event_file = File.join(repo, ".github_event.json")
    File.write(event_file, JSON.generate(payload))
    env = { "GITHUB_EVENT_NAME" => event, "GITHUB_EVENT_PATH" => event_file,
            "GITHUB_SHA" => git("rev-parse", "HEAD"), "GITHUB_OUTPUT" => output }
    err = StringIO.new
    previous = [$stdout, $stderr]
    $stdout = StringIO.new
    $stderr = err
    begin
      expect(described_class.main(["gate=#{gate}"], root: repo, env: env)).to eq(0)
    ensure
      $stdout, $stderr = previous
    end
    [File.read(output)[/touched=(\w+)/, 1], err.string]
  end

  def pull_request(base) = { "pull_request" => { "base" => { "sha" => base } } }

  before do
    git("init", "-q", "-b", "main")
    commit("README.md")
  end

  it "runs the runtime gate for a change under lib/hecks/runtime/" do
    base = git("rev-parse", "HEAD")
    commit("lib/hecks/runtime/dispatch.rb")

    expect(touched("runtime_changed", event: "pull_request", payload: pull_request(base)).first).to eq("true")
  end

  it "skips the runtime gate for a change that leaves lib/hecks/runtime/ alone" do
    base = git("rev-parse", "HEAD")
    commit("docs/notes.md", "lib/hecks/other.rb")

    expect(touched("runtime_changed", event: "pull_request", payload: pull_request(base)).first).to eq("false")
  end

  it "treats a base it cannot diff against as a reason to run, and says so" do
    commit("docs/notes.md")

    answer, err = touched("runtime_changed", event: "pull_request", payload: pull_request("deadbeef" * 5))
    expect([answer, err]).to match(["true", /git diff itself failed/])
  end

  it "treats no base at all as a reason to run" do
    commit("docs/notes.md")

    answer, err = touched("runtime_changed", event: "pull_request", payload: {})
    expect([answer, err]).to match(["true", /no usable base/])
  end

  it "answers false when the diff is empty" do
    head = git("rev-parse", "HEAD")

    expect(touched("runtime_changed", event: "pull_request", payload: pull_request(head)).first).to eq("false")
  end

  it "refuses a gate no CiGate row names" do
    expect { described_class.main(["gate=no_such_gate"], root: repo, env: {}) }
      .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      .and output(/no CiGate row named no_such_gate/).to_stderr
  end

  it "refuses a call that names no gate" do
    expect { described_class.main([], root: repo, env: {}) }
      .to raise_error(SystemExit)
      .and output(/name a gate/).to_stderr
  end

  context "with the allowlist gate" do
    it "skips a change made only of skippable paths" do
      base = git("rev-parse", "HEAD")
      commit("docs/notes.md", "rust/host/src/web.rs", "CHANGELOG.md")

      expect(touched("postgres_io_relevant_changed", event: "pull_request", payload: pull_request(base)).first)
        .to eq("false")
    end

    it "runs when any changed path falls outside the allowlist" do
      base = git("rev-parse", "HEAD")
      commit("docs/notes.md", "lib/hecks/other.rb")

      expect(touched("postgres_io_relevant_changed", event: "pull_request", payload: pull_request(base)).first)
        .to eq("true")
    end

    it "diffs a push against the commit before it" do
      before = git("rev-parse", "HEAD")
      commit("lib/hecks/other.rb")

      expect(touched("postgres_io_relevant_changed", event: "push", payload: { "before" => before }).first)
        .to eq("true")
    end

    it "runs on a push whose before commit is the null sha" do
      commit("docs/notes.md")

      answer, err = touched("postgres_io_relevant_changed", event: "push", payload: { "before" => "0" * 40 })
      expect([answer, err]).to match(["true", /no usable base/])
    end
  end

  # A merge group diffs against the target branch, never against the previous queue entry:
  # #729 (docs only) rode behind a red #730 on 2026-09-18 because the gate saw only its own files.
  context "when the run is a merge group" do
    it "sees the files of the entries queued before it" do
      git("update-ref", "refs/remotes/origin/main", "HEAD")
      commit("lib/hecks/runtime/dispatch.rb")
      previous_entry = git("rev-parse", "HEAD")
      commit("docs/notes.md")

      payload = { "merge_group" => { "base_sha" => previous_entry, "base_ref" => "refs/heads/main" } }
      expect(touched("runtime_changed", event: "merge_group", payload: payload).first).to eq("true")
    end
  end
end

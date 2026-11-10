require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/claude_agents"

# The `Agents` port's adapter, against a stand-in for the `claude` command: it records what it was
# asked and where, prints a session id for a start, and lists the sessions a spec writes. No real
# session is ever started.
RSpec.describe Hecks::Adapters::ClaudeAgents do
  # Prints a session id for a start and the listing for `agents`; records its arguments, directory.
  STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    printf '%s\\n' "$@" > "$here/argv"
    pwd -P > "$here/cwd"
    printf 'backgrounded · session-id-abc123\\n  claude agents    list sessions\\n  claude stop session-id-abc123    stop this session\\n'
  SH

  let(:scratch) { File.realpath(Dir.mktmpdir("claude-agents")) }
  let(:stand_in) { File.join(scratch, "claude") }
  let(:adapter) { described_class.new(settings: { command: stand_in, launcher: "/main/exe/hecks" }) }

  def install(script)
    File.write(stand_in, script)
    File.chmod(0o755, stand_in)
  end

  def listing(*sessions) = File.write(File.join(scratch, "sessions.json"), JSON.generate(sessions))

  def asked = File.read(File.join(scratch, "argv")).split("\n")

  def start(**held) = adapter.start(repo: { value: scratch }, brief: { value: "say ok" }, **held)

  before { install(STAND_IN) }

  after { FileUtils.rm_rf(scratch) }

  describe "#locate" do
    # Answers a probe for an agent it does not have as `claude` does, naming the agents it has.
    LISTING = "#!/bin/sh\necho \"--agent '$2' not found. Available agents: claude, Explore, coder\" >&2\nexit 1\n".freeze

    it "says a directory is there, and that with no agent named there is nothing to look for" do
      expect(adapter.locate(repo: { value: scratch }))
        .to eq(report: { value: "#{scratch} is a directory" }, listed: true,
               note: "no agent named: the session runs the default agent")
    end

    it "says an agent the directory's claude lists is listed" do
      install(LISTING)

      expect(adapter.locate(repo: { value: scratch }, agent: { value: "coder" })).to include(listed: true)
    end

    it "says an agent it does not list is not, naming the ones it does" do
      install(LISTING)

      expect(adapter.locate(repo: { value: scratch }, agent: { value: "nope" }))
        .to include(listed: false, note: "agent nope is not available in #{scratch}; available: claude, Explore, coder")
    end

    it "refuses when claude names no agents, saying what it said" do
      install("#!/bin/sh\necho something else\nexit 1\n")

      expect { adapter.locate(repo: { value: scratch }, agent: { value: "coder" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /listed no agents: something else/)
    end

    it "refuses a directory that is not there" do
      expect { adapter.locate(repo: { value: File.join(scratch, "absent") }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /absent is not a directory/)
    end
  end

  describe "#start" do
    def settings_asked = asked[asked.index("--settings") + 1]

    it "answers the session the command printed, and when it started" do
      expect(start).to match(session:    { value: "session-id-abc123" },
                             started_at: { value: /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/ })
    end

    it "starts it in the directory, with the agent and its caller name, in the background, brief after --", :aggregate_failures do
      start(agent: { value: "miette" })

      expect(asked).to eq(["--agent", "miette", "--settings", %({"env":{"HECKS_CALLER":"miette"}}), "--bg", "--", "say ok"])
      expect(File.read(File.join(scratch, "cwd")).strip).to eq(scratch)
    end

    it "names the run in the settings env block, so its commands are logged under it" do
      start(run: { value: "fix-it" }, agent: { value: "coder" })

      expect(JSON.parse(settings_asked).fetch("env")).to eq("HECKS_CALLER" => "coder:fix-it")
    end

    it "adds a Stop and a SessionEnd hook that check the run through the launcher", :aggregate_failures do
      start(run: { value: "fix-it" }, agent: { value: "coder" })

      hooks = JSON.parse(settings_asked).fetch("hooks")
      expect(hooks.keys).to eq(%w[PostToolUse Stop SessionEnd])
      expect(hooks["Stop"].first["hooks"].last["command"]).to include("/main/exe/hecks AgentRun.check! to=fix-it")
    end

    it "adds a PostToolUse and a Stop hook that read the run's inbox", :aggregate_failures do
      start(run: { value: "fix-it" }, agent: { value: "coder" })

      hooks = JSON.parse(settings_asked).fetch("hooks")
      expect(hooks["PostToolUse"].first["hooks"].first["command"]).to include("inbox/fix-it.md")
      expect(hooks["Stop"].first["hooks"].first["command"]).to include("inbox/fix-it.md")
    end

    it "adds no hooks to a session that names no run" do
      start(agent: { value: "miette" })

      expect(JSON.parse(settings_asked)).not_to have_key("hooks")
    end

    it "adds the verdict format to the architect's brief, and to no other agent's", :aggregate_failures do
      start(agent: { value: "architect" })
      expect(asked.join("\n")).to include("say ok", "make the last line of your closing message", "Verdict: rethink")

      start(agent: { value: "reviewer" })
      expect(asked.last).to eq("say ok")
    end

    it "leaves the agent out when none is named, and keeps a brief that looks like a flag" do
      start(brief: { value: "--dangerously-skip-permissions" })

      expect(asked).to eq(["--bg", "--", "--dangerously-skip-permissions"])
    end

    it "refuses when the command fails, saying why" do
      install("#!/bin/sh\necho no login >&2\nexit 3\n")

      expect { start }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /did not start a session: no login/)
    end

    it "refuses when the command names no session" do
      install("#!/bin/sh\nexit 0\n")

      expect { start }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /named no session/)
    end
  end

  describe "#resume" do
    def resume(**held) = adapter.resume(session: { value: "abc123" }, repo: { value: scratch }, **held)

    # Logs a stop, records a resume's arguments, directory and session variables, and says what
    # `copy` holds (if set) as `claude` does when it starts a copy.
    RESUME_STAND_IN = <<~SH.freeze
      #!/bin/sh
      here=$(dirname "$0")
      polls() { if [ -f "$here/stopped" ]; then cat "$here/polls" 2>/dev/null || echo 0; else echo 99; fi; }
      if [ "$1" = "agents" ]; then
        n=$(polls); echo $((n + 1)) > "$here/polls"
        if [ -f "$here/stopped" ] && [ "$n" -ge 2 ]; then sed 's/"state":"[a-z]*"/"state":"stopped"/' "$here/sessions.json"; else cat "$here/sessions.json"; fi
        exit 0
      fi
      if [ "$1" = "stop" ]; then
        echo "$2" >> "$here/stopped"; echo 0 > "$here/polls"
        if [ -f "$here/pid" ]; then (sleep 0.8; kill "$(cat "$here/pid")") >/dev/null 2>&1 & fi
        exit 0
      fi
      if [ -f "$here/pid" ] && kill -0 "$(cat "$here/pid")" 2>/dev/null; then touch "$here/copy"; fi
      printf '%s\\n' "$@" > "$here/argv"
      pwd -P > "$here/cwd"
      env | grep '^CLAUDE' | sort > "$here/claude_env"
      if [ -f "$here/copy" ] || [ "$(polls)" -lt 2 ]; then
        echo "note: ${here}/copy started a copy as copy-9f3e21" >&2; echo "backgrounded · copy-9f3e21"
      else
        echo "note: woke session abc123 with its saved options (--model)." >&2; echo "backgrounded · abc123"
      fi
    SH

    def listed_as(state) = listing({ "id" => "abc123", "sessionId" => "abc123-0000-full", "state" => state })

    def stopped = File.exist?(File.join(scratch, "stopped")) ? File.read(File.join(scratch, "stopped")).split("\n") : []

    def copy_says(text) = File.write(File.join(scratch, "copy"), text)

    before do
      install(RESUME_STAND_IN)
      listed_as("stopped")
    end

    it "resumes the session by its full id in the run's directory, with the answer after --", :aggregate_failures do
      result = resume(answer: { value: "--keep-going" })

      expect(asked).to eq(["--bg", "--resume", "abc123-0000-full", "--", "[pipeline answer] --keep-going"])
      expect(File.read(File.join(scratch, "cwd")).strip).to eq(scratch)
      expect(result.dig(:resumed_at, :value)).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "keeps the run's own session id when the session woke in place" do
      expect(resume(answer: { value: "go on" })).to include(session: { value: "abc123" })
    end

    it "names the run's role with --agent, ahead of the session id, so its MCP server narrows again" do
      resume(answer: { value: "go on" }, agent: { value: "orchestrator" })
      expect(asked).to eq(["--agent", "orchestrator", "--bg", "--resume", "abc123-0000-full", "--", "[pipeline answer] go on"])
    end

    it "names no agent for a run that has none, so the session resumes as it did before" do
      resume(answer: { value: "go on" })
      expect(asked).to eq(["--bg", "--resume", "abc123-0000-full", "--", "[pipeline answer] go on"])
    end

    it "stops a session that is still running before it resumes it", :aggregate_failures do
      listed_as("blocked")
      resume(answer: { value: "go on" })

      expect(stopped).to eq(["abc123"])
      expect(asked).to include("--resume")
    end

    it "does not stop a session that is already stopped" do
      resume(answer: { value: "go on" })
      expect(stopped).to be_empty
    end

    # Sets `CLAUDE*` variables for the block and puts the environment back.
    def with_claude_env(**vars)
      saved = ENV.to_h
      ENV.keys.grep(/\ACLAUDE/).each { |name| ENV.delete(name) }
      vars.each { |name, value| ENV[name.to_s] = value }
      yield
    ensure
      ENV.replace(saved)
    end

    it "runs the resume without the calling session's CLAUDE* variables, keeping its config" do
      with_claude_env(CLAUDE_CODE_AGENT: "planner", CLAUDE_EFFORT: "high", CLAUDE_CONFIG_DIR: "/kept") do
        resume(answer: { value: "go on" })
      end

      expect(File.read(File.join(scratch, "claude_env"))).to eq("CLAUDE_CONFIG_DIR=/kept\n")
    end

    it "follows the copy when the CLI started one, and surfaces its note from stderr", :aggregate_failures do
      copy_says("yes")

      expect(resume(answer: { value: "go on" })).to include(session: { value: "copy-9f3e21" },
                                                            note:    { value: a_string_including("started a copy") })
    end

    it "waits until the stopped session reads stopped before it resumes, so no copy is started", :aggregate_failures do
      listed_as("blocked")
      result = resume(answer: { value: "go on" })

      expect(result).to include(session: { value: "abc123" })
      expect(File.read(File.join(scratch, "polls")).to_i).to be >= 3
    end

    # A process standing for the session's, listed with its pid; the stand-in kills it 0.8s after
    # `stop`, long after the listing reads stopped, and starts a copy for a resume while it lives.
    def session_process
      pid = Process.spawn("sleep", "30")
      Process.detach(pid)
      File.write(File.join(scratch, "pid"), pid.to_s)
      listing({ "id" => "abc123", "sessionId" => "abc123-0000-full", "state" => "blocked", "pid" => pid })
      pid
    end

    it "waits for the session's process to exit after the listing reads stopped", :aggregate_failures do
      pid = session_process
      result = resume(answer: { value: "go on" })

      expect(result).to include(session: { value: "abc123" })
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end

    it "follows the id the CLI backgrounded when it differs from the run's, whatever the note says" do
      install(RESUME_STAND_IN.sub("echo \"backgrounded · abc123\"", "echo \"backgrounded · other-77aa\""))

      expect(resume(answer: { value: "go on" })).to include(session: { value: "other-77aa" })
    end

    it "refuses a session that is not listed, and starts nothing" do
      listing({ "id" => "other", "sessionId" => "other-full" })
      expect { resume(answer: { value: "x" }) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no session abc123/)
    end

    it "refuses when the command refuses, saying why" do
      install("#!/bin/sh\nif [ \"$1\" = agents ]; then cat \"$(dirname \"$0\")/sessions.json\"; exit 0; fi\n" \
              "echo no such session >&2\nexit 1\n")

      expect { resume(answer: { value: "x" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /resume abc123 refused: no such session/)
    end
  end

  describe "#read_job" do
    let(:jobs) { File.join(scratch, "jobs") }
    let(:adapter) { described_class.new(settings: { command: stand_in, jobs: jobs, settle: 0, projects: scratch }) }

    def job(state, detail, output = nil)
      FileUtils.mkdir_p(File.join(jobs, "abc123"))
      File.write(File.join(jobs, "abc123", "state.json"), JSON.generate({ state: state, detail: detail, output: output }.compact))
    end

    def read(**held) = adapter.read_job(session: { value: "abc123" }, repo: { value: scratch }, **held)

    it "answers the job's state and detail, the held condition, and the directory with its slash" do
      job("blocked", "which branch?")

      expect(read(condition: { value: "working" })).to include(state: "blocked", detail: "which branch?",
                                                               previous: "working", checkout: "#{scratch}/")
    end

    it "carries the Work item the run serves, so the verdict policies can name it" do
      job("done", "reviewed", { result: "Verdict: sound" })

      expect(read(agent: { value: "architect" }, work: { value: "fix-it" })).to include(verdict: "sound", work: "fix-it")
    end

    it "answers no Work item for a run that serves none, so a hand-started run stays unrecorded" do
      job("done", "reviewed", { result: "Verdict: sound" })

      expect(read(agent: { value: "architect" })).to include(work: "")
    end

    it "reads the architect's verdict and findings off the closed job", :aggregate_failures do
      job("done", "reviewed", { result: "Verdict: sound with changes. Rename the port." })

      answer = read(agent: { value: "architect" })
      expect(answer).to include(verdict: "changes", judgment: "")
      expect(answer[:findings]).to include("Rename the port")
    end

    it "takes the verdict from the last Verdict line, not from a word elsewhere in the text" do
      job("done", "reviewed", { result: "The plan is sound in parts, but the ports are wrong.\nVerdict: rethink" })

      expect(read(agent: { value: "architect" })).to include(verdict: "rethink")
    end

    it "reads a Verdict line the architect set in bold or with a closing period" do
      job("done", "reviewed", { result: "Findings follow.\n**Verdict: sound with changes.** Rename the port." })

      expect(read(agent: { value: "architect" })).to include(verdict: "changes")
    end

    # The job's timeline, whose last entry keeps only the tail of what the session wrote.
    def timeline(text)
      entry = { at: "t", state: "done", detail: "reviewed", text: text }
      File.write(File.join(jobs, "abc123", "timeline.jsonl"), "#{JSON.generate(entry)}\n")
    end

    it "reads the verdict off the tail of the session's last timeline entry", :aggregate_failures do
      job("done", "reviewed")
      timeline("ersion of the plan.\n5 findings.\nVerdict: sound with changes")

      answer = read(agent: { value: "architect" })
      expect(answer).to include(verdict: "changes")
      expect(answer[:findings]).to include("5 findings")
    end

    # The session's transcript, which holds its closing message whole.
    def closing_message(text)
      FileUtils.mkdir_p(File.join(scratch, "-repo"))
      entry = { type: "assistant", isSidechain: false, message: { content: [{ type: "text", text: text }] } }
      File.write(File.join(scratch, "-repo", "abc123-0000-full.jsonl"), "#{JSON.generate(entry)}\n")
    end

    def long_review = "The ports are wrong, so the plan is reworked.\n#{"x" * 5000}\nVerdict: rethink"

    # A job whose timeline keeps only the review's tail, and a transcript that keeps it whole.
    def long_review_job
      job("done", "reviewed")
      timeline(long_review[-2000..])
      closing_message(long_review)
    end

    it "keeps a 5000-character finding's first line and its last line", :aggregate_failures do
      long_review_job
      answer = read(agent: { value: "architect" })
      expect(answer).to include(verdict: "rethink", findings: start_with("The ports are wrong"))
      expect(answer[:findings]).to end_with("\nVerdict: rethink")
    end

    it "takes the verdict and findings from the first text that says something, not all three joined" do
      job("done", "sound", { result: "Verdict: rethink" })

      expect(read(agent: { value: "architect" })).to include(verdict: "rethink", findings: "Verdict: rethink")
    end

    it "reads the reviewer's judgment off the closed job, and no verdict" do
      job("done", "judged", { result: "One failure is a stale expectation." })

      expect(read(agent: { value: "reviewer" })).to include(judgment: "stale_expectation", verdict: "")
    end

    it "reports no verdict or judgment for any other agent" do
      job("done", "sound and a real bug", { result: "sound, real bug" })

      expect(read(agent: { value: "coder" })).to include(verdict: "", judgment: "")
    end

    it "answers an empty previous state for a run that has recorded none" do
      job("working", nil)

      expect(read).to include(previous: "", detail: "")
    end

    it "refuses a session that has no job" do
      expect { read }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no job state at .*abc123/)
    end

    it "reads the same way once a new session has settled" do
      job("failed", "exit 1 before init")

      expect(adapter.await_job(session: { value: "abc123" }, repo: { value: scratch })).to include(state: "failed")
    end
  end
end

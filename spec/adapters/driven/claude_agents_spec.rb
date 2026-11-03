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
  let(:starts) { File.join(scratch, "starts") }
  let(:adapter) { described_class.new(settings: { command: stand_in, starts: starts }) }

  def install(script)
    File.write(stand_in, script)
    File.chmod(0o755, stand_in)
  end

  def listing(*sessions) = File.write(File.join(scratch, "sessions.json"), JSON.generate(sessions))

  def asked = File.read(File.join(scratch, "argv")).split("\n")

  def start(**held) = adapter.start(repo: { value: scratch }, brief: { value: "say ok" }, run: { value: "run-1" }, **held)

  def launches = File.exist?(File.join(scratch, "launches")) ? File.readlines(File.join(scratch, "launches")).size : 0

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
    it "answers the session the command printed" do
      expect(start).to eq(session: { value: "session-id-abc123" })
    end

    it "starts it in the directory, with the agent, in the background, and the brief after --", :aggregate_failures do
      start(agent: { value: "miette" })

      expect(asked).to eq(["--agent", "miette", "--bg", "--", "say ok"])
      expect(File.read(File.join(scratch, "cwd")).strip).to eq(scratch)
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

    it "launches a run once: a redelivered start is refused before claude runs again", :aggregate_failures do
      install("#!/bin/sh\necho launched >> #{scratch}/launches\necho backgrounded · session-id-abc123\n")

      start
      expect { start }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /run run-1 was already started/)
      expect(launches).to eq(1)
    end

    it "starts each run separately" do
      install("#!/bin/sh\necho launched >> #{scratch}/launches\necho backgrounded · session-id-abc123\n")

      start(run: { value: "run-1" })
      start(run: { value: "run-2" })
      expect(launches).to eq(2)
    end

    it "releases the claim when the command fails outright, so a retry can start", :aggregate_failures do
      install("#!/bin/sh\necho no login >&2\nexit 3\n")
      expect { start }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /did not start a session/)

      install(STAND_IN)
      expect(start).to eq(session: { value: "session-id-abc123" })
    end

    it "keeps the claim when the command names no session, since its outcome is unknown", :aggregate_failures do
      install("#!/bin/sh\nexit 0\n")
      expect { start }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /stays claimed/)

      install(STAND_IN)
      expect { start }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /already started/)
    end
  end

  describe "#read_job" do
    let(:jobs) { File.join(scratch, "jobs") }
    let(:adapter) { described_class.new(settings: { command: stand_in, jobs: jobs, settle: 0 }) }

    def job(state, detail)
      FileUtils.mkdir_p(File.join(jobs, "abc123"))
      File.write(File.join(jobs, "abc123", "state.json"), JSON.generate(state: state, detail: detail))
    end

    def read(**held) = adapter.read_job(session: { value: "abc123" }, repo: { value: scratch }, **held)

    it "answers the job's state and detail, the held condition, and the directory with its slash" do
      job("blocked", "which branch?")

      expect(read(condition: { value: "working" }))
        .to eq(state: "blocked", detail: "which branch?", previous: "working", checkout: "#{scratch}/")
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

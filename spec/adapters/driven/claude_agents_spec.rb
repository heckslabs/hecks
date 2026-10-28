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
  let(:adapter) { described_class.new(settings: { command: stand_in }) }

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
    it "says a directory is there" do
      expect(adapter.locate(repo: { value: scratch })).to eq(report: { value: "#{scratch} is a directory" })
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
  end

  describe "#examine" do
    before { listing({ id: "abc123", sessionId: "full-abc123", state: "busy" }, { id: "def456", state: "done" }) }

    it "answers the state a session reports, found by id" do
      expect(adapter.examine(session: { value: "def456" })).to eq(condition: "done")
    end

    it "finds a session by its full session id" do
      expect(adapter.examine(session: { value: "full-abc123" })).to eq(condition: "busy")
    end

    it "refuses a session that is not listed" do
      expect { adapter.examine(session: { value: "zzz" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no session zzz is listed/)
    end
  end
end

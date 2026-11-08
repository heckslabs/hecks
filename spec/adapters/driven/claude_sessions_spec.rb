require "spec_helper"
require "hecks/hecks/adapters/claude_sessions"
require "tmpdir"
require "fileutils"
require "json"

# The `ClaudeSessions` adapter against a stand-in `claude` that keeps a session listed until it is
# stopped when a `sticky` file stands.
RSpec.describe Hecks::Adapters::ClaudeSessions do
  let(:scratch) { File.realpath(Dir.mktmpdir("retire-claude")) }
  let(:command) { File.join(scratch, "claude") }
  let(:adapter) { described_class.new(settings: { command: command }) }

  after { FileUtils.rm_rf(scratch) }

  def stand_in(sticky:)
    listing = [{ id: "s9", sessionId: "s9-full", name: "n", state: "working" }]
    File.write(File.join(scratch, "sessions.json"), JSON.generate(listing))
    FileUtils.touch(File.join(scratch, "sticky")) if sticky
    File.write(command, SCRIPT)
    File.chmod(0o755, command)
  end

  SCRIPT = <<~SH.freeze
    #!/bin/sh
    d=$(dirname "$0"); echo "$*" >> "$d/calls.log"
    case "$1" in
      agents) cat "$d/sessions.json" ;;
      stop) rm -f "$d/sticky" ;;
      rm) [ -f "$d/sticky" ] || echo '[]' > "$d/sessions.json" ;;
    esac
  SH

  def calls = File.readlines(File.join(scratch, "calls.log"), chomp: true).grep_v(/\Aagents/)

  it "removes with rm alone when that unlists the session" do
    stand_in(sticky: false)
    adapter.withdraw(session: "s9")

    expect(calls).to eq(["rm s9"])
  end

  it "stops, then removes again, a session that rm left listed" do
    stand_in(sticky: true)
    adapter.withdraw(session: "s9")

    expect(calls).to eq(["rm s9", "stop s9", "rm s9"])
  end

  it "reports a session that holds no run as bound to none" do
    stand_in(sticky: false)

    expect(adapter.examine(session: "s9")).to include(run: "", bound: false, working: true)
  end
end

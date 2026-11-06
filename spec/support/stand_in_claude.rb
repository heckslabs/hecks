# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# A spec that starts agent runs gets a stand-in `claude` first, so it can never start a real
# session. The stand-in names the agents the roles use, lists one session, and starts nothing. The
# job's state and the session list sit in `scratch`; `HOME` and `PATH` point there for the example.
STAND_IN_CLAUDE = <<~SH
  #!/bin/sh
  here=$(dirname "$0")
  if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
  if [ "$1" = "rm" ]; then shift; echo "$*" >> "$here/rm.log"; exit 0; fi
  if [ "$1" = "--agent" ] && [ "$2" = "hecks-probe-not-an-agent" ]; then
    printf 'Available agents: architect, coder, orchestrator, planner, release_manager, reviewer\\n'; exit 0
  fi
  printf 'backgrounded · stand-in-session\\n'
SH

RSpec.shared_context "with a stand-in claude" do
  let(:scratch) { File.realpath(Dir.mktmpdir("stand-in-claude")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), STAND_IN_CLAUDE)
    File.chmod(0o755, File.join(scratch, "claude"))
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", state: "working" }]))
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "working"))
    ENV["PATH"] = "#{scratch}:#{env["PATH"]}"
    ENV["HOME"] = scratch
    example.run
  ensure
    ENV.update(env)
    FileUtils.rm_rf(scratch)
  end

  before do
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0 })
    end)
  end
end

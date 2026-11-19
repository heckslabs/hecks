require "json"
require "tmpdir"
require "fileutils"
require_relative "agents_memory_boot"

# Steers stand-in sessions through the Agents bluebook's `Fleet` port: a listing, transcripts under
# a temporary projects directory, and ledger facts, all named here. The shell records each
# `claude` command it is asked to run and runs none, so no example reaches a real session.
module AgentsFleetHelpers
  PORTS = [File.join(InMemoryDomain::ROOT, "lib/hecks/agents/agents.ports.hecksagon"),
           File.join(InMemoryDomain::ROOT, "lib/hecks/agents/adapters/fleet_control.adapter")].freeze

  # A shell that answers `claude agents` with the listing and every other command with `ok`.
  class RecordingShell
    attr_reader :commands

    def initialize(listing, succeeds: true)
      @listing = listing
      @succeeds = succeeds
      @commands = []
    end

    def capture(*command, chdir: nil, **)
      return result(JSON.generate(@listing), true) if command[1] == "agents"

      @commands << { command: command, chdir: chdir }
      result("", @succeeds)
    end

    private

    def result(out, succeeded)
      Hecks::Adapters::Shell::Result.new(out, succeeded ? "" : "no such session", Struct.new(:success?).new(succeeded))
    end
  end

  def listing
    [{ "id" => "aaaa1111", "sessionId" => "aaaa1111-full", "name" => "coder-one", "state" => "done", "status" => "idle" },
     { "id" => "bbbb2222", "sessionId" => "bbbb2222-full", "name" => "orchestrator", "state" => "working", "status" => "busy" },
     { "id" => "cccc3333", "sessionId" => "cccc3333-full", "name" => "plain", "state" => "stopped", "status" => "idle" }]
  end

  def ledger
    { runs: { "fix-it" => { status: "started", condition: "working" } }, sessions: { "aaaa1111-full" => "fix-it" },
      pinned: ["orchestrator"] }
  end

  def shell = (@shell ||= RecordingShell.new(listing))

  def projects = (@projects ||= Dir.mktmpdir("fleet-projects"))

  # Writes a transcript for a session, each line one user entry of the given text.
  def transcript(session, *texts, cwd: "/work/#{session}")
    FileUtils.mkdir_p(File.join(projects, "-work"))
    lines = texts.map { |text| JSON.generate("type" => "user", "cwd" => cwd, "message" => { "content" => text }) }
    File.write(File.join(projects, "-work", "#{session}.jsonl"), lines.join("\n"))
  end

  def fleet = Hecks::Adapters::FleetControl.new(settings: { shell: shell, projects: projects, runs: -> { ledger } })

  def boot_fleet = AgentsMemoryBoot.call(extra: PORTS)

  # Runs one Fleet command through the bluebook with the stand-in adapter, and reads its record.
  def steer(command, session, **attributes)
    adapter = fleet
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { adapter }) do
      Hecks::Agents::Fleet.public_send(command, session: { value: session }, **attributes)
    end
    Hecks::Agents::Fleet.find(session)
  end
end

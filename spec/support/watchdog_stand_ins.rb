# frozen_string_literal: true

require "json"
require "tmpdir"

# Stand-ins for what the watchdog's loop reaches: a `claude` that answers from a script, and a
# clock that is moved by hand. Nothing here signals a process or touches the owner's sessions.
module WatchdogStandIns
  Result = Struct.new(:out, :err, :ok) { alias_method :ok?, :ok }

  # A shell that records each call and answers `claude` from the sessions it is told are listed.
  class Shell
    attr_reader :calls, :detached
    attr_accessor :listed, :daemon_up

    def initialize(listed: [], daemon_up: true)
      @listed = listed
      @daemon_up = daemon_up
      @calls = []
      @detached = []
    end

    def capture(*argv, chdir: nil)
      @calls << { argv: argv, chdir: chdir }
      return Result.new(JSON.generate(@listed), "", true) if argv.first(3) == %w[claude agents --json]
      return Result.new("", "", @daemon_up) if argv.first(3) == %w[claude daemon status]

      Result.new("", "", true)
    end

    def detach(*argv, **) = @detached << argv

    def resumes = @calls.select { |call| call[:argv].include?("--resume") }
  end

  def roster_of(*names)
    sessions = names.map { |name| { "name" => name, "cwd" => "/work/#{name}", "loops" => [loop_row] } }
    { "sessions" => sessions, "settings" => settings }
  end

  def loop_row = { "kind" => "cron", "schedule" => "7,37 * * * *", "prompt" => "watch pass" }

  def settings
    { "pass_seconds" => "30", "dead_states" => "stopped,done,failed", "mass_kill_window" => "60",
      "mass_kill_count" => "2", "loops_grace" => "120", "held_nice" => "20", "held_priority" => "4" }
  end

  def entry(name, state, id: "id-#{name}") = { "id" => id[0, 8], "sessionId" => id, "name" => name, "state" => state }
end

# frozen_string_literal: true

require "rbconfig"
require_relative "probe"
require_relative "board_footprint"
require_relative "../../hecks/adapters/main_integration/code_watch"

module Hecks
  module Adapters
    module PipelineBoard
      # When the board serves for long, it grows. It restarts itself, as the command that
      # started it, once it holds more memory than the Hecks world's `board_restart` line
      # allows or has run for longer than that line says, and it reads its state at the same
      # line's `refresh_seconds`. The check runs in the snapshot loop after each read.
      class BoardRestart
        # The limits when the Hecks world declares no `board_restart` line.
        DEFAULTS = { rss_mb: 1024, age_hours: 24, refresh_seconds: 30, min_uptime_seconds: 600,
                     loaded_refresh_seconds: 60 }.freeze
        # The resident-memory line of `/proc/self/status`, in kilobytes.
        PROC_RSS = /VmRSS:\s+(\d+)/

        # @param registry [Runtime::Registry, nil]
        # @return [Hash{Symbol => Numeric}] `rss_mb`, `age_hours`, `refresh_seconds`,
        #   `min_uptime_seconds` (the time a board runs before any limit can restart it) and
        #   `loaded_refresh_seconds` (the read period while the machine is loaded)
        def self.limits(registry)
          world = registry&.world("Hecks")
          declared = world ? world.for_verb("board_restart") : {}
          DEFAULTS.merge(declared.slice(*DEFAULTS.keys)).transform_values { |value| Float(value) }
        end

        # @param limits [Hash{Symbol => Numeric}] from {.limits}
        # @param command [Array<String>] the program and arguments that started the board; the
        #   script is taken as an absolute path so a restart does not depend on the working
        #   directory
        # @param host [Hash] stand-ins for the outside: `memory:` (answers this process's resident
        #   memory in megabytes), `now:` (answers the time), `restart:` (takes the command and
        #   replaces this process with it) and `code_moved:` (answers whether the code on disk is no
        #   longer the code this process loaded; the watch starts here, so its baseline is the code
        #   the board began with)
        def initialize(limits:, command: [RbConfig.ruby, File.expand_path($PROGRAM_NAME), *ARGV], **host)
          @code_moved = host[:code_moved] || MainIntegration::CodeWatch.shared.method(:moved?)
          @limits = limits
          @command = command
          @directory = Dir.pwd
          @memory = host.fetch(:memory) { method(:resident_mb) }
          @now = host.fetch(:now) { -> { Time.now } }
          @restart = host[:restart] || method(:replace_process)
          @started = @now.call
        end

        # Restarts the board when it is over a limit and has run for the minimum uptime; does
        # nothing otherwise, so a board that starts above a limit cannot restart in a loop.
        # @return [Symbol, nil] `:memory` or `:age` when it restarted (a stand-in `restart` returns)
        def check
          reason = @code_moved.call ? :code : settled_reason
          @restart.call(@command) if reason
          reason
        end

        private

        # A board whose code changed on disk restarts at once; the limits wait out the uptime.
        def settled_reason = uptime < @limits.fetch(:min_uptime_seconds, 0) ? nil : over

        def uptime = @now.call - @started

        def over
          return :age if uptime > @limits[:age_hours] * 3600

          :memory if @memory.call > @limits[:rss_mb]
        end

        # Replaces this process with the command, in the directory the board started in. The
        # environment, which holds RUBYOPT, carries over; other interpreter flags do not.
        def replace_process(argv) = exec(*argv, chdir: @directory)

        # Megabytes held: resident from `/proc` where there is one, else the physical footprint
        # where `footprint` answers (macOS, whose resident size counts freed pages), else resident
        # from `ps`; 0 when none answers.
        def resident_mb
          status = "/proc/self/status"
          return File.read(status)[PROC_RSS, 1].to_i / 1024.0 if File.exist?(status)

          footprint_mb || (Probe.run("ps", "-o", "rss=", "-p", Process.pid.to_s).to_i / 1024.0)
        rescue Unavailable, SystemCallError
          0.0
        end

        def footprint_mb
          BoardFootprint.megabytes(Process.pid) if BoardFootprint.available?
        rescue Unavailable
          nil
        end
      end
    end
  end
end

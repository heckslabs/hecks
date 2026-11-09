# frozen_string_literal: true

require "rbconfig"
require_relative "probe"

module Hecks
  module Adapters
    module PipelineBoard
      # When the board serves for long, it grows. It restarts itself, as the command that
      # started it, once it holds more memory than the Hecks world's `board_restart` line
      # allows or has run for longer than that line says, and it reads its state at the same
      # line's `refresh_seconds`. The check runs in the snapshot loop after each read.
      class BoardRestart
        # The limits when the Hecks world declares no `board_restart` line.
        DEFAULTS = { rss_mb: 1024, age_hours: 24, refresh_seconds: 30, min_uptime_seconds: 600 }.freeze
        # The resident-memory line of `/proc/self/status`, in kilobytes.
        PROC_RSS = /VmRSS:\s+(\d+)/

        # @param registry [Runtime::Registry, nil]
        # @return [Hash{Symbol => Numeric}] `rss_mb`, `age_hours`, `refresh_seconds` and
        #   `min_uptime_seconds`, the time a board runs before any limit can restart it
        def self.limits(registry)
          world = registry&.world("Hecks")
          declared = world ? world.for_verb("board_restart") : {}
          DEFAULTS.merge(declared.slice(*DEFAULTS.keys)).transform_values { |value| Float(value) }
        end

        # @param limits [Hash{Symbol => Numeric}] from {.limits}
        # @param command [Array<String>] the program and arguments that started the board; the
        #   script is taken as an absolute path so a restart does not depend on the working directory
        # @param memory [#call] answers this process's resident memory in megabytes
        # @param now [#call] answers the time
        # @param restart [#call] takes the command and replaces this process with it
        def initialize(limits:, command: [RbConfig.ruby, File.expand_path($PROGRAM_NAME), *ARGV],
                       memory: method(:resident_mb), now: -> { Time.now }, restart: nil)
          @limits = limits
          @command = command
          @directory = Dir.pwd
          @memory = memory
          @now = now
          @restart = restart || method(:replace_process)
          @started = now.call
        end

        # Restarts the board when it is over a limit and has run for the minimum uptime; does
        # nothing otherwise, so a board that starts above a limit cannot restart in a loop.
        # @return [Symbol, nil] `:memory` or `:age` when it restarted (a stand-in `restart` returns)
        def check
          return nil if uptime < @limits.fetch(:min_uptime_seconds, 0)

          reason = over
          @restart.call(@command) if reason
          reason
        end

        private

        def uptime = @now.call - @started

        def over
          return :age if uptime > @limits[:age_hours] * 3600

          :memory if @memory.call > @limits[:rss_mb]
        end

        # Replaces this process with the command, in the directory the board started in. The
        # environment, which holds RUBYOPT, carries over; other interpreter flags do not.
        def replace_process(argv) = exec(*argv, chdir: @directory)

        # Resident megabytes from `/proc` where there is one, else from `ps`; 0 when neither
        # answers.
        def resident_mb
          status = "/proc/self/status"
          return File.read(status)[PROC_RSS, 1].to_i / 1024.0 if File.exist?(status)

          Probe.run("ps", "-o", "rss=", "-p", Process.pid.to_s).to_i / 1024.0
        rescue Unavailable, SystemCallError
          0.0
        end
      end
    end
  end
end

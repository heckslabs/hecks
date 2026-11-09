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
        DEFAULTS = { rss_mb: 1024, age_hours: 24, refresh_seconds: 30 }.freeze
        # The resident-memory line of `/proc/self/status`, in kilobytes.
        PROC_RSS = /VmRSS:\s+(\d+)/

        # @param registry [Runtime::Registry, nil]
        # @return [Hash{Symbol => Numeric}] `rss_mb`, `age_hours` and `refresh_seconds`
        def self.limits(registry)
          world = registry&.world("Hecks")
          declared = world ? world.for_verb("board_restart") : {}
          DEFAULTS.merge(declared.slice(*DEFAULTS.keys)).transform_values { |value| Float(value) }
        end

        # @param limits [Hash{Symbol => Numeric}] from {.limits}
        # @param command [Array<String>] the program and arguments that started the board
        # @param memory [#call] answers this process's resident memory in megabytes
        # @param now [#call] answers the time
        # @param restart [#call] takes the command and replaces this process with it
        def initialize(limits:, command: [RbConfig.ruby, $PROGRAM_NAME, *ARGV], memory: method(:resident_mb),
                       now: -> { Time.now }, restart: ->(argv) { exec(*argv) })
          @limits = limits
          @command = command
          @memory = memory
          @now = now
          @restart = restart
          @started = now.call
        end

        # Restarts the board when it is over a limit; does nothing otherwise.
        # @return [Symbol, nil] `:memory` or `:age` when it restarted (a stand-in `restart` returns)
        def check
          reason = over
          @restart.call(@command) if reason
          reason
        end

        private

        def over
          return :age if (@now.call - @started) > @limits[:age_hours] * 3600

          :memory if @memory.call > @limits[:rss_mb]
        end

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

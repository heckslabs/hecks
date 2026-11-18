# frozen_string_literal: true

require "net/http"
require "open3"
require_relative "../restart_notes"

module Hecks
  module Adapters
    module PipelineBoard
      # The sentinel's outside, as the real process sees it (see {Sentinel::Host}).
      class Sentinel
        # The real outside of a {Sentinel}: the board's page on 127.0.0.1, its process, and the
        # command that started it.
        class Host
          # Seconds the page has to answer one ask.
          ASK_SECONDS = 10
          # Seconds the board has to end once asked to stop, before it is made to.
          GRACE_SECONDS = 5
          # A `ps` time: optional days, then `M:SS`, `H:MM:SS` with optional fractions of a second.
          PS_TIME = /\A(?:(\d+)-)?(\d+(?::\d+){1,2}(?:\.\d+)?)\z/

          # @param pid [Integer] the board's process id
          # @param port [Integer] the port the board serves on
          # @param command [Array<String>] the program and arguments that started the board
          # @param directory [String] where the board was started
          def initialize(pid:, port:, command:, directory:)
            @pid = pid
            @port = port
            @command = command
            @directory = directory
          end

          # @return [Boolean] whether the page answered with any status within {ASK_SECONDS}
          def answered?
            Net::HTTP.start("127.0.0.1", @port, open_timeout: ASK_SECONDS, read_timeout: ASK_SECONDS) { |http| http.get("/") }
            true
          rescue SystemCallError, Timeout::Error, IOError
            false
          end

          # @param pid [Integer] the board's process id
          # @return [Float, nil] the CPU seconds the process has used, from `ps`; nil when the
          #   process is gone or `ps` fails
          def cpu_seconds(pid)
            out, status = Open3.capture2("ps", "-o", "time=", "-p", pid.to_s)
            status.success? ? self.class.cpu_time(out) : nil
          rescue SystemCallError
            nil
          end

          # @param text [String] a `ps` time: `M:SS.ss`, `H:MM:SS` or `D-HH:MM:SS`
          # @return [Float, nil] its seconds; nil when it is not a time
          def self.cpu_time(text)
            days, clock = text.strip.match(PS_TIME)&.captures
            return nil unless clock

            (days.to_i * 86_400) + clock.split(":").map(&:to_f).reduce { |sum, part| (sum * 60) + part }
          end

          # @return [Float] monotonic seconds, for the wall time between two asks
          def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # @return [Boolean] whether the board is still this process's parent
          def parent_alive? = Process.ppid == @pid

          # @param seconds [Numeric] how long to wait
          def pause(seconds) = sleep(seconds)

          # Ends the board: asks it to stop, then forces it when the grace has passed.
          # @param pid [Integer] the board's process id
          def stop(pid)
            Process.kill("TERM", pid)
            sleep(GRACE_SECONDS)
            Process.kill("KILL", pid)
          rescue Errno::ESRCH
            nil
          end

          # Starts the board again as the command that started it, detached, in its directory, and
          # notes the restart for the board's header.
          # @param misses [Integer] the asks in a row that led to the restart
          # @param reason [String] `stall` or `cpu`, for the note
          # @return [Integer] the new board's process id
          def restart(misses: 0, reason: "stall")
            RestartNotes.record(misses: misses, reason: reason)
            child = Process.spawn({ Sentinel::ENV_KEY => nil }, *@command, chdir: @directory, pgroup: true)
            Process.detach(child)
            child
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require "rbconfig"
require_relative "../sentinel"
require_relative "../board_restart"
require_relative "host"

module Hecks
  module Adapters
    module PipelineBoard
      # The way a board stands its {Sentinel}: once per environment, as a detached process.
      class Sentinel
        # The environment name carrying the sentinel's pid, so a board that restarts itself
        # (`exec` keeps the pid, the environment and the child) does not start a second one.
        ENV_KEY = "PIPELINE_BOARD_SENTINEL"
        # The checkout's `lib`, which the sentinel process is not given by the environment.
        LIB = File.expand_path("../../../..", __dir__)

        class << self
          # Starts the sentinel process for this board unless one already stands for it or the
          # limits switch it off (`sentinel_seconds` of 0).
          #
          # @param port [Integer] the port the board serves on
          # @param registry [Runtime::Registry, nil] whose Hecks world's `board_restart` line sets
          #   `sentinel_seconds` and `sentinel_misses`
          # @param command [Array<String>] how the board was started
          # @return [Integer, nil] the sentinel's pid; nil when none was started
          def stand(port:, registry: nil, command: [RbConfig.ruby, File.expand_path($PROGRAM_NAME), *ARGV])
            limits = BoardRestart.limits(registry)
            return nil if limits[:sentinel_seconds].to_f <= 0 || standing?

            spec = { pid: Process.pid, port: port, command: command, directory: Dir.pwd,
                     every: limits[:sentinel_seconds], misses: limits[:sentinel_misses].to_i }
            child = Process.spawn(*command(spec), pgroup: true)
            Process.detach(child)
            ENV[ENV_KEY] = child.to_s
          end

          # @param spec [Hash] the board's pid, port, command and directory, and the sentinel's
          #   `every` and `misses`
          # @return [Array<String>] the interpreter and arguments that run a sentinel from `spec`,
          #   with this checkout's `lib` on the load path its code requires from
          def command(spec) = [RbConfig.ruby, "-I", LIB, __FILE__, JSON.generate(spec)]

          # @return [Boolean] whether the sentinel this environment names is still running
          def standing?
            pid = ENV.fetch(ENV_KEY, "").to_i
            pid.positive? && Process.kill(0, pid) == 1
          rescue SystemCallError
            false
          end

          # Runs a sentinel from the JSON {.stand} passed on the command line.
          # @param json [String] the spec
          def from_spec(json)
            spec = JSON.parse(json, symbolize_names: true)
            host = Host.new(**spec.slice(:pid, :port, :command, :directory))
            new(**spec.slice(:pid, :every, :misses), host: host).run
          end
        end
      end
    end
  end
end

Hecks::Adapters::PipelineBoard::Sentinel.from_spec(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__

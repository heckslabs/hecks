# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "../console_capture"

module Hecks
  module Adapters
    class GitTrain
      # What a boarding does when it is told to stop (its resident restarted, a person interrupted):
      # it records a fault, so the end is not silent, and refuses by name. The record is one JSON
      # file in the repository's common git directory, written whole and moved into place. The
      # board and the orchestrator read it; the next boarding that carries a commit removes it.
      class Termination
        # The fault record's file name.
        FILE = "hecks-train-fault.json"

        # The signals that end a boarding.
        SIGNALS = %w[TERM INT HUP].freeze

        # The refusal a terminated boarding raises.
        class Stopped < ConsoleCapture::Failure; end

        # @param common_dir [String] the repository's common git directory
        # @param branch [String] the boarded branch
        def initialize(common_dir, branch)
          @path = File.join(common_dir, FILE)
          @branch = branch
          @step = "waiting for the line"
        end

        # @param step [String] what the boarding is doing now, named in a fault
        # @return [void]
        def at(step) = @step = step

        # Runs the block with the stopping signals trapped, then restores them.
        #
        # @return [Object] what the block answers
        # @raise [Stopped] when a signal arrived, after the fault is recorded
        def watch
          main = Thread.current
          old = SIGNALS.to_h { |name| [name, Signal.trap(name) { |_| stop(name, main) }] }
          yield.tap { FileUtils.rm_f(@path) }
        ensure
          old&.each { |name, handler| Signal.trap(name, handler) }
        end

        private

        def stop(signal, main)
          record(signal)
          main.raise(Stopped, "the boarding of #{@branch} was terminated by SIG#{signal} while #{@step}; " \
                              "nothing was pushed (fault recorded in #{@path})")
        end

        def record(signal)
          fault = { "branch" => @branch, "signal" => signal, "step" => @step, "at" => Time.now.utc.iso8601 }
          File.write("#{@path}.tmp", JSON.generate(fault))
          File.rename("#{@path}.tmp", @path)
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    # Optional JSONL samples from the landing train and integration coordinator.
    module PipelineTiming
      module_function

      def record(stage, **fields)
        path = ENV.fetch("HECKS_PIPELINE_TIMING", nil)
        return if path.nil? || path.empty?

        line = JSON.generate(fields.merge(stage: stage, at: Time.now.to_f))
        File.open(path, "a") do |file|
          file.flock(File::LOCK_EX)
          file.write(line << "\n")
        end
      rescue SystemCallError, IOError
        nil
      end

      def measure(stage, **fields)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        record(stage, seconds: elapsed, **fields)
      end
    end
  end
end

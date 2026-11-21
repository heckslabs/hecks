# frozen_string_literal: true

require "shellwords"

module Hecks
  module Adapters
    # The shell command a stopping session runs to check its run once, and only when its job's
    # state changed. The hook's input names the session; after one settle wait the command
    # fingerprints the job's `state.json` (the file the check reads) and compares it with the one
    # kept for the run after its last successful check. The same fingerprint boots nothing. A
    # session the input does not name, or a job with no state file, is checked every time, and a
    # failed check keeps no fingerprint, so the next stop checks again.
    #
    # Only the job's state is compared: the minutes a blocked or running job has waited depend on
    # the clock, and the sweep evaluates those.
    class StateGate
      # @param jobs [String] the jobs directory, `~` already expanded
      # @param seen [String] the directory holding each run's last checked fingerprint
      # @param settle [Numeric] seconds waited before the state is read
      def initialize(jobs:, seen:, settle:)
        @jobs = Shellwords.escape(jobs)
        @seen = Shellwords.escape(seen)
        @settle = settle
      end

      # @param run [String] the key of the run the session belongs to
      # @param check [String] the command that checks the run
      # @return [String] the shell command
      def command(run, check)
        marker = "#{@seen}/#{Shellwords.escape(run.to_s.tr("/", "_"))}"
        [read_session, "sleep #{@settle}", fingerprint, skip_unchanged(marker), record(check, marker), "exit 0"].join("; ")
      end

      private

      def read_session = "s=$(sed -n 's/.*\"session_id\": *\"\\([^\"]*\\)\".*/\\1/p' | head -n 1)"

      def fingerprint = "sum=; [ -n \"$s\" ] && sum=$(cksum < #{@jobs}/\"$s\"/state.json 2>/dev/null)"

      def skip_unchanged(marker)
        "if [ -n \"$sum\" ] && [ \"$sum\" = \"$(cat #{marker} 2>/dev/null)\" ]; then exit 0; fi"
      end

      def record(check, marker)
        "#{check} && [ -n \"$sum\" ] && { mkdir -p #{@seen}; echo \"$sum\" > #{marker}; }"
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../../../hecks"

module Hecks
  module QualityControlCli
    # The tick's push check: dispatches `PushNudge.Check` once in the Hecks domain, where Tickets
    # keeps the Work items, and prints that it ran. It reads refs git already holds and fetches,
    # pushes and merges nothing. It never fails a tick: a check that could not run prints why and
    # exits 0, since a missing nudge must not stop the sweep.
    class QaPushNudge
      EXIT_OK = 0

      # Everything up to the first line break.
      FIRST_LINE = /[^\n]*/

      # Runs the check.
      #
      # @param _argv [Array<String>] unused
      # @param root [String] the repository root, whose `lib/hecks/hecks` domain is booted
      # @return [Integer] 0, always
      def self.call(_argv, root:)
        new(root: root).call
      end

      # @param root [String] the repository root
      def initialize(root:)
        @root = root
      end

      # @return [Integer] 0, always
      def call
        runtime = Hecks.boot(File.join(@root, "lib/hecks/hecks"))
        key = "check-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}"
        runtime.dispatch_flat("QualityControl::PushNudge.Check", nudge: { value: key })
        puts "push nudge: checked (#{key}); the push-due Work item is filed, revised or finished"
        EXIT_OK
      rescue StandardError => e
        puts "push nudge: skipped (#{e.class}: #{first_line(e.message)})"
        EXIT_OK
      end

      private

      def first_line(text) = text[FIRST_LINE].strip
    end
  end
end

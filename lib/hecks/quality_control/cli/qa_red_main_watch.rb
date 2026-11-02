# frozen_string_literal: true

require_relative "../../../hecks"
require_relative "../adapters/main_ci_reader"
require_relative "../../hecks/adapters/red_main_line"

module Hecks
  module QualityControlCli
    # The tick's red-main watch: when the latest finished `CI` run on `main` failed, one open
    # `red-main-<run id>` Work row names the failing job; when a later run passes, the red-main rows
    # it settles are finished. It files through the Tickets domain, reads GitHub through a port
    # (`MainCiReader`), and is idempotent: a second tick over the same run files nothing. It never
    # fails a tick, and it never blocks a push: red main blocks promotion to stable, not pushes.
    class QaRedMainWatch
      EXIT_OK = 0

      # Everything up to the first line break.
      FIRST_LINE = /[^\n]*/

      PREFIX = Adapters::RedMainLine::PREFIX

      # @param _argv [Array<String>] unused
      # @param root [String] the repository root, whose `lib/hecks/hecks` domain is booted
      # @return [Integer] 0, always
      def self.call(_argv, root:)
        runtime = Hecks.boot(File.join(root, "lib/hecks/hecks"))
        new(runtime: runtime).call
      rescue StandardError => e
        puts "red main: skipped (#{e.class}: #{e.message[FIRST_LINE].strip})"
        EXIT_OK
      end

      # @param runtime [Runtime] the booted Hecks domain, where Tickets keeps the Work rows
      # @param reader [#runs] the GitHub port; `MainCiReader` when nil
      def initialize(runtime:, reader: nil)
        @runtime = runtime
        @reader = reader || Adapters::MainCiReader.new
      end

      # @return [Integer] 0, always
      def call
        latest = @reader.runs.first
        return say("red main: no finished CI run read; nothing to do") unless latest

        latest.conclusion == "failure" ? file(latest) : settle(latest)
        EXIT_OK
      end

      private

      def file(run)
        key = "#{PREFIX}#{run.id}"
        open_keys = open_rows.map { |row| row[:id].to_s }
        (open_keys - [key]).each { |other| finish(other) }
        return say("red main: #{key} is open (#{run.failed_job})") if open_keys.include?(key)

        plan(key, run)
        say("red main: filed #{key} (#{run.failed_job})")
      end

      def settle(run)
        return say("red main: latest CI run #{run.id} is #{run.conclusion}; nothing to settle") unless run.conclusion == "success"

        closed = open_rows.map { |row| finish(row[:id].to_s) }
        say(closed.empty? ? "red main: green (#{run.id})" : "red main: #{run.id} passed; finished #{closed.join(", ")}")
      end

      def plan(key, run)
        detail = "main is red since #{run.created_at}: #{run.failed_job}"
        @runtime.dispatch_flat("Tickets::Work.Plan", work: { value: key }, area: [],
                                                     title: { value: "main is red: #{run.failed_job}" },
                                                     detail: { value: detail })
      end

      def finish(key)
        @runtime.dispatch_flat("Tickets::Work.Finish", to: key)
        key
      end

      def open_rows = Adapters::RedMainLine.open_rows(@runtime.registry)

      def say(text)
        puts text
        EXIT_OK
      end
    end
  end
end

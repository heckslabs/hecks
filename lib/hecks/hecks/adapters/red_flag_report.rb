# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    # Says a standing red flag in words: its id, the commit, how long main has been red, the failed
    # jobs, and who has checked in to help and what they took. The pipeline board and the status
    # query print the same sentence.
    class RedFlagReport
      # @param flag [Hash] the marker's content
      # @param now [Time] the time the elapsed red time is measured to
      def initialize(flag, now: Time.now)
        @flag = flag
        @now = now
      end

      # @return [Integer] seconds main has been red
      def elapsed_seconds
        [(@now - Time.iso8601(@flag.fetch("raised_at"))).to_i, 0].max
      rescue ArgumentError, KeyError
        0
      end

      # @return [String] the whole sentence, one line per fact
      def text
        [headline, jobs_line, work_items_line, *helper_lines].compact.join("\n")
      end

      # @return [String] the one-line form for a tile
      def headline
        "main is red: #{@flag["id"]} at #{@flag["commit"].to_s[0, 10]}, red for #{elapsed_seconds / 60} min, " \
          "#{@flag["runs"].to_a.size} red run(s), #{@flag["checkins"].to_a.size} helping"
      end

      private

      def jobs_line
        jobs = seen("jobs")
        "failing jobs: #{jobs.join("; ")}" unless jobs.empty?
      end

      def work_items_line
        items = seen("work_items")
        "red work items: #{items.join(", ")}" unless items.empty?
      end

      # The distinct, non-empty values of one field across the red runs.
      def seen(field)
        values = @flag["runs"].to_a.map { |run| run[field].to_s }
        values.reject(&:empty?).uniq
      end

      def helper_lines
        @flag["checkins"].to_a.map { |entry| "helping: #{entry["session"]} takes #{entry["taking"]}" }
      end
    end
  end
end

# frozen_string_literal: true

require "open3"

module Hecks
  module QualityControlCli
    # The tick's bloat watch: runs `exe/hecks Dispatch.watch! confirm.value=true --wait` in the
    # repository and prints the rows it found and what it did. It never fails a tick: a watch that
    # could not run prints why and exits 0, since a missing watch must not stop the sweep.
    class QaBloatWatch
      EXIT_OK = 0

      # The line of the state a command prints that carries the report.
      REPORT = /"report": "((?:[^"\\]|\\.)*)"/

      # @param _argv [Array<String>] unused
      # @param root [String] the repository root
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
        out, err, status = Open3.capture3("exe/hecks", "Dispatch.watch!", "repo.value=#{@root}", "confirm.value=true", "--wait", chdir: @root)
        puts "bloat watch: #{status.success? ? report(out) : "skipped (#{err.lines.first.to_s.strip})"}"
        EXIT_OK
      rescue StandardError => e
        puts "bloat watch: skipped (#{e.class}: #{e.message.lines.first.to_s.strip})"
        EXIT_OK
      end

      private

      def report(out) = out[REPORT, 1].to_s.gsub("\\n", "; ").then { |text| text.empty? ? "ran" : text }
    end
  end
end

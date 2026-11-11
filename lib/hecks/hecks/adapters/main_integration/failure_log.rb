# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    class MainIntegration
      # Keeps what a failed verification check printed in a file that outlives the clean copy it
      # ran in, and reads from that output the spec file and the first failing example. A log
      # holds the check's last `LINES` lines; the directory keeps the newest `KEEP` logs.
      class FailureLog
        # How many logs the directory keeps.
        KEEP = 20

        # How many of a check's last output lines a log holds.
        LINES = 400

        # The spec file a launcher or rspec failure report names.
        SPEC_FILE = /rspec (\S+_spec\.rb)/

        # The first numbered failure of an rspec report: its example's description.
        FIRST_EXAMPLE = /^\s+1\) (.+)$/

        # What a check's name may not hold in a file name.
        UNSAFE_NAME = /[^a-z0-9]+/i

        # @param directory [String] where the logs are kept
        def initialize(directory)
          @directory = directory
        end

        # @param output [String] what a failed check printed
        # @return [Hash{Symbol => String}] the `:spec` file and `:example` the output names;
        #   a key is absent when the output does not name it
        def self.finding(output)
          text = output.to_s
          { spec: text[SPEC_FILE, 1], example: text[FIRST_EXAMPLE, 1]&.strip }.compact
        end

        # Writes the log of one failed check and prunes the directory to the newest `KEEP`.
        #
        # @param landed [String] the commit that failed verification
        # @param name [String] the failed check's name
        # @param argv [Array<String>] the check's command line
        # @param output [String] what the check printed
        # @return [String] the log's path
        def keep(landed, name, argv, output)
          FileUtils.mkdir_p(@directory)
          path = File.join(@directory, "#{landed[0, 10]}-#{name.gsub(UNSAFE_NAME, "-")}-#{stamp}.log")
          File.write(path, "#{argv.join(" ")}\n\n#{bounded(output)}")
          newest_first.drop(KEEP).each { |old| FileUtils.rm_f(old) }
          path
        end

        private

        def bounded(output)
          lines = output.to_s.lines
          lines.last(LINES).join
        end

        def stamp = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)

        # The logs in the directory, newest first.
        def newest_first
          paths = Dir.children(@directory).map { |file| File.join(@directory, file) }
          paths.sort_by { |path| [File.mtime(path), path] }.reverse
        end
      end
    end
  end
end

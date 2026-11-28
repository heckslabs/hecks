# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module Hecks
  module Adapters
    class CrewHarness
      # A replay did not do what its journal says, or could not be run.
      class NotReplayed < StandardError; end

      # A crew run's journal, read by the `hecks-harness` binary: one recording a session, written
      # by `serve --record`. The binary outlines it, tapes each recording, and holds a replay's
      # journal to it act by act; this only calls it and words what it answers.
      class Journal
        attr_reader :dir

        # @param dir [String] the journal's directory
        # @param binary [String] the `hecks-harness` binary
        # @raise [NotReplayed] when the binary is not built or there is no journal at `dir`
        def initialize(dir, binary:)
          @dir = File.expand_path(dir)
          @binary = binary
          raise NotReplayed, "the hecks-harness binary is not built at #{@binary}" unless File.executable?(@binary)
          raise NotReplayed, "no journal at #{@dir}" unless File.directory?(@dir)
        end

        # @return [Hash{String => Integer}] the turns each session ended in the run
        def turns
          @turns ||= JSON.parse(harness("journal", @dir)).transform_values { |counts| counts.fetch("turns") }
        end

        # Writes each session's recording into `into` as a replay tape.
        #
        # @param into [String] the directory the tapes are written to
        # @return [String] `into`
        def taped(into)
          FileUtils.mkdir_p(into)
          turns.each_key do |session|
            File.write(File.join(into, "#{session}.jsonl"), harness("tape", File.join(@dir, "#{session}.jsonl")))
          end
          into
        end

        # Holds a replay's journal to this one.
        #
        # @param replay [String] the replay's journal
        # @return [String] how many acts of how many sessions the replay did as this journal has
        #   them
        # @raise [NotReplayed] naming each session's first act done otherwise, or when the two
        #   cannot be compared
        def held_by(replay)
          out, status = Open3.capture2(@binary, "compare", @dir, replay)
          raise NotReplayed, "cannot compare #{@dir} with its replay" unless [0, 1].include?(status.exitstatus)

          compared = JSON.parse(out)
          raise NotReplayed, diverged(compared) unless compared.fetch("held")

          "replayed #{compared.fetch("matched")} acts of #{compared.fetch("sessions")} sessions, each as the journal has it"
        end

        private

        # Each session's first surprise, in a sentence.
        def diverged(compared)
          surprises = compared.fetch("surprises").map do |surprise|
            "#{surprise.fetch("session")} at act #{surprise.fetch("at") + 1}: the journal has " \
              "#{told(surprise["journal"])}, the replay #{told(surprise["replay"])}"
          end
          "the replay did otherwise: #{surprises.join("; ")}"
        end

        def told(act) = act ? JSON.generate(act) : "nothing"

        def harness(*args)
          out, err, status = Open3.capture3(@binary, *args)
          raise NotReplayed, err.strip.empty? ? "hecks-harness #{args.first} failed" : err.strip unless status.success?

          out
        end
      end
    end
  end
end

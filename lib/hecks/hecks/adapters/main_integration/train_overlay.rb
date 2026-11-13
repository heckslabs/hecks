# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    class MainIntegration
      # The machine-local overlay of the push train's copy, written from the one list of aggregates
      # the train needs kept between processes. The copy is a checkout of its own, so the overlay of
      # the development checkout does not reach it; writing it here, each time the copy is brought
      # to a commit, keeps it from being a hand copy that falls behind.
      class TrainOverlay
        # Where the overlay is, relative to a checkout.
        PATH = File.join("lib", "hecks", "hecks", "hecks.local.hecksagon")

        # The aggregates whose records a later process of the train reads back: the boarding, the
        # landing and its worktree, the revision, the run of an agent, the clock chain of a
        # queued pull request, whose every tick is a launcher call of its own, and each failed
        # attempt of a train pull request's CI, whose failed jobs are read after a rerun clears
        # them. The main checkout's overlay binds the same aggregates to the same database.
        PERSISTED = %w[AgentRun Revision Landing LinkedTree SendTrain Ticker TrainPr].freeze

        # The comment that opens the file.
        HEADER = <<~TEXT
          # Written by the push train each time its copy is brought to a commit, from the aggregates
          # `MainIntegration::TrainOverlay::PERSISTED` names. Gitignored; never committed, never edited.
        TEXT

        # @param root [String] the train's copy
        def initialize(root)
          @root = root
        end

        # The overlay's text.
        #
        # @return [String]
        def text
          lines = PERSISTED.map { |name| "  Hecks::#{name}.persisted_by(\"SqlitePersistence\")" }
          [HEADER, 'Hecks.hecksagon "Hecks" do', '  persisted_by "Memory"', *lines, "end", ""].join("\n")
        end

        # Writes the overlay when the copy's differs.
        #
        # @return [String, nil] the path written, or nil when the copy's was already this
        def write
          path = File.join(@root, PATH)
          return if File.file?(path) && File.read(path) == text

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, text)
          path
        end
      end
    end
  end
end

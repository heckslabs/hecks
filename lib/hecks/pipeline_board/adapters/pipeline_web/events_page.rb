# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The Events page, answered by the board's web adapter at `/events`: every event the event
      # log's tail holds, each with the reactions it caused, what it links to and what the
      # bluebooks say of it. The page joins the events with the wiring graph itself, so serving
      # it reads the log's tail and nothing more.
      module EventsPage
        # The page file.
        PATH = File.expand_path("events.html", __dir__)
        # How many of the event log's newest lines the page is given the events of. A line is an
        # event or one policy's answer to it, so this is about half as many events.
        KEPT = 3000

        # @return [String] the Events page
        def events_page = File.read(PATH)

        # @return [Hash] `events:` the newest events, newest first, each with its `key`, `at`,
        #   `aggregate`, `id`, `name`, `reactions`, `links`, `correlation` and `source`, or the
        #   reader's `{unknown: reason}`
        def journal = { events: @stages ? @stages.journal_feed(KEPT) : [] }
      end
    end

    # Reopened here so the reader of the longer feed sits beside the page that asks for it.
    class PipelineStages
      # @param lines [Integer] how many of the event log's newest lines
      # @return [Array<Hash>, Hash] their events, newest first, or `{unknown: reason}`
      def journal_feed(lines) = guard { @journal.history(lines) }
    end

    # Reopened here for the same reason: only the Events page asks for the longer tail.
    class PipelineJournal
      # @param lines [Integer] how many of the event log's newest lines
      # @return [Array<Hash>] their events, newest first; none when no log is written
      def history(lines) = (@longer ||= @tap.longer(lines)).rows.reverse
    end

    # Reopened here so the Events page's readers sit beside the page they read.
    class PipelineWeb
      include PipelineBoard::EventsPage
    end
  end
end

# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's per-item URLs: `/runs/<run>` for an AgentRun (its key or its session id) and
      # `/trains/<run>` for a SendTrain boarding. `/runs/<run>` answers the board page, which reads
      # the key from its path and highlights that session row in place; `/trains/<run>` answers the
      # Events page, which reads the key from its path and opens with its search set to it. Under
      # `/api` each answers the item as JSON, for tools. A key is letters, digits, dots, dashes and
      # underscores, so no other path reaches a reader.
      module DeepLinks
        ROUTE = %r{\A(?<api>/api)?/(?<kind>runs|trains)/(?<key>[A-Za-z0-9][A-Za-z0-9._-]{0,127})\z}
        READERS = { "runs" => :run_detail, "trains" => :train_detail }.freeze
        PAGES = { "runs" => :page, "trains" => :events_page }.freeze

        # @param path [String] a request path
        # @return [MatchData, nil] the route's `api`, `kind` and `key`, nil for any other path
        def self.match(path) = ROUTE.match(path)

        # @param app [#page, #events_page, #run_detail, #train_detail] what serves the pages and
        #   reads an item
        # @param route [MatchData] a {.match} result
        # @return [Array(Integer, String, String)] the status, content type and body to answer with:
        #   the board page for a run and the Events page for a boarding, the item's JSON (404 when
        #   nothing has the key) under `/api`, and 503 with the reason when the records cannot be
        #   read
        def self.answer(app, route)
          return [200, "text/html; charset=utf-8", app.public_send(PAGES.fetch(route[:kind]))] unless route[:api]

          kind, key = route.values_at(:kind, :key)
          detail = app.public_send(READERS.fetch(kind), key)
          [detail ? 200 : 404, "application/json", JSON.generate(detail || { unknown: "no #{kind} item #{key}" })]
        rescue PipelineBoard::Unavailable => e
          [503, "text/plain", e.message]
        end
      end
    end
  end
end

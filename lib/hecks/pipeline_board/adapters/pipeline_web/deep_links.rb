# frozen_string_literal: true

require "cgi"
require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's per-item URLs: `/runs/<run>` for an AgentRun (its key or its session id) and
      # `/trains/<run>` for a SendTrain boarding, each as a page and as JSON under `/api`. A key is
      # letters, digits, dots, dashes and underscores, so no other path reaches a reader.
      module DeepLinks
        ROUTE = %r{\A(?<api>/api)?/(?<kind>runs|trains)/(?<key>[A-Za-z0-9][A-Za-z0-9._-]{0,127})\z}
        WEB_URL = %r{\Ahttps?://}
        TITLES = { "runs" => "Agent run", "trains" => "Push train boarding" }.freeze
        STYLE = "body{font:15px/1.5 system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem}" \
                "dt{font-weight:600;margin-top:.8rem}dd{margin:0}pre{white-space:pre-wrap;background:#f4f4f4;padding:.6rem}"

        # @param path [String] a request path
        # @return [MatchData, nil] the route's `api`, `kind` and `key`, nil for any other path
        def self.match(path) = ROUTE.match(path)

        # @param app [#run_detail, #train_detail] what reads an item
        # @param route [MatchData] a {.match} result
        # @return [Array(Integer, String, String)] the status, content type and body to answer with
        def self.answer(app, route)
          kind, key = route.values_at(:kind, :key)
          detail = app.public_send(kind == "runs" ? :run_detail : :train_detail, key)
          status = detail ? 200 : 404
          return [status, "application/json", JSON.generate(detail || { unknown: "no #{kind} item #{key}" })] if route[:api]

          [status, "text/html; charset=utf-8", page(kind, key, detail)]
        rescue PipelineBoard::Unavailable => e
          [503, "text/plain", e.message]
        end

        # @param kind [String] `runs` or `trains`
        # @param key [String] the item's key
        # @param detail [Hash, nil] what the app knows of the item
        # @return [String] the page; a note that nothing has that key when the detail is nil
        def self.page(kind, key, detail)
          title = "#{TITLES.fetch(kind)} #{CGI.escapeHTML(key)}"
          body = detail ? rows(kind, detail) : "<p>No #{TITLES.fetch(kind).downcase} has the key #{CGI.escapeHTML(key)}.</p>"
          "<!doctype html><html><head><meta charset=\"utf-8\"><title>#{title}</title><style>#{STYLE}</style></head>" \
            "<body><p><a href=\"/\">Pipeline Board</a> · <a href=\"/agents\">Agents</a></p><h1>#{title}</h1>#{body}</body></html>"
        end

        # @return [String] the definition list of a run's or a boarding's fields
        def self.rows(kind, detail)
          fields = kind == "runs" ? run_fields(detail) : train_fields(detail)
          "<dl>#{fields.map { |name, html| "<dt>#{name}</dt><dd>#{html}</dd>" }.join}</dl>"
        end

        RUN_TEXT = { "Work item" => :work, "Agent role" => :agent, "Status" => :status, "Condition" => :condition,
                     "Session" => :session, "Repo" => :repo, "Refusal" => :refusal }.freeze
        TRAIN_TEXT = { "Run" => :run, "Status" => :status, "Outcome" => :outcome, "Boarded commit" => :boarded,
                       "Pushed commit" => :pushed }.freeze

        def self.run_fields(run)
          shown = RUN_TEXT.transform_values { |name| text(run[name]) }
          shown.merge("Landed" => commits(run[:commits]), "Brief" => pre(run[:brief]),
                      "Detail (final report)" => pre(run[:detail]))
        end

        def self.train_fields(train)
          shown = TRAIN_TEXT.transform_values { |name| text(train[name]) }
          shown.merge("Pull request" => pull_request(train[:pr]), "Checks" => checks(train[:pr]),
                      "Report" => pre(train[:report]))
        end

        def self.pull_request(request)
          request ? link(request[:url], "##{request[:number]} (#{request[:state]})") : "-"
        end

        def self.commits(list)
          shown = Array(list).map { |item| item[:url] ? link(item[:url], item[:sha]) + ci(item[:ci_url]) : text(item[:sha]) }
          shown.empty? ? "-" : shown.join(", ")
        end

        def self.ci(url) = url ? " (#{link(url, "CI run")})" : ""

        def self.checks(request)
          list = request ? request[:checks] : []
          list.empty? ? "-" : list.map { |check| "#{link(check[:url], check[:name])}: #{text(check[:result])}" }.join("<br>")
        end

        def self.link(url, label)
          return text(label) unless url.to_s.match?(WEB_URL)

          "<a href=\"#{CGI.escapeHTML(url)}\" rel=\"noopener\">#{text(label)}</a>"
        end

        def self.text(value) = value.to_s.empty? ? "-" : CGI.escapeHTML(value.to_s)

        def self.pre(value) = value.to_s.empty? ? "-" : "<pre>#{CGI.escapeHTML(value.to_s)}</pre>"
      end
    end
  end
end

# frozen_string_literal: true

require "cgi"

module Hecks
  module Adapters
    module PipelineBoard
      # One Work item's row on the planning page: a cell in its lane's colour, its title and key,
      # its priority and status when they say something (a priority that is set, a status other
      # than planned), its area, the session running it and for how long, and the note its plan
      # reviews leave.
      module PlanItem
        VERDICT = { "changes" => "sound with changes" }.freeze
        # The values every row would repeat, so the row leaves them out.
        QUIET = %w[unset planned].freeze

        module_function

        # @param row [Hash] a row of {PlanReading}
        # @return [String] the row's HTML, carrying the attributes the page's filters match
        def draw(row)
          "<div class=\"item\"#{marks(row)}><i class=\"cell c-#{esc(row[:lane])}\"></i>" \
            "<span class=\"what\">#{esc(row[:title])} <code>#{esc(row[:slug])}</code></span>" \
            "#{chip(status(row))}#{area(row)}#{priority(row)}#{facts(row)}#{review(row[:reviewed])}</div>"
        end

        # @return [String] the `data-` attributes the page's filters match
        def marks(row)
          pairs = { priority: row[:priority], status: status(row), epic: row[:epic], area: Array(row[:area]).join(", ") }
          pairs.map { |name, value| " data-#{name}=\"#{esc(value)}\"" }.join
        end

        # @return [String] the link to the session running the item, or its id as text
        def session_link(row) = "<a href=\"/runs/#{esc(row[:session])}\">session</a> #{row[:minutes] || "?"} min"

        def status(row) = row[:yield_count].to_i.positive? ? "yielded" : row[:status].to_s

        def chip(word) = QUIET.include?(word.to_s) ? "" : " <span class=\"chip k-#{esc(word)}\">#{esc(word)}</span>"

        # The priority as a quiet word: the row's cell already carries its colour.
        def priority(row)
          QUIET.include?(row[:priority].to_s) ? "" : " <span class=\"pri\">#{esc(row[:priority])}</span>"
        end

        def area(row)
          named = Array(row[:area]).join(", ")
          named.empty? ? "" : " <span class=\"area\">#{esc(named)}</span>"
        end

        def facts(row)
          parts = [yielded(row), budget(row), running(row)].compact
          parts.empty? ? "" : " <span class=\"facts\">#{parts.join("; ")}</span>"
        end

        def yielded(row)
          return unless row[:yield_count].to_i.positive? || !row[:reason].to_s.empty?

          "yielded #{row[:yield_count].to_i}#{": #{esc(row[:reason])}" unless row[:reason].to_s.empty?}"
        end

        def budget(row) = row[:budget_minutes].to_i.positive? ? "budget #{row[:budget_minutes]} min" : nil

        def running(row) = row[:session] ? "running #{session_link(row)}" : nil

        def review(reviews)
          return "" if reviews.empty?

          latest = reviews.last
          "<details class=\"review\"><summary>reviewed #{reviews.size} time#{"s" unless reviews.size == 1}, latest verdict " \
            "#{esc(VERDICT.fetch(latest[:verdict].to_s, latest[:verdict].to_s))}</summary>" \
            "<pre>#{esc(latest[:findings])}</pre>#{earlier(reviews[0...-1])}</details>"
        end

        def earlier(reviews)
          return "" if reviews.empty?

          body = reviews.reverse.map { |review| "<pre>#{esc(review[:verdict])}: #{esc(review[:findings])}</pre>" }.join
          "<details><summary>Earlier reviews (#{reviews.size})</summary>#{body}</details>"
        end

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

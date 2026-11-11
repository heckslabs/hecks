# frozen_string_literal: true

require "cgi"

module Hecks
  module Adapters
    module PipelineBoard
      # The HTML of the tiles the board pushes: what goes inside the element a tile owns on the
      # page.
      # The server draws a tile once, from the same reading that holds its data, so the page holds
      # no second copy of the drawing. A tile whose reading failed says why and nothing else.
      module TileHtml
        ICON = { "ok" => "✓", "working" => "◔", "attention" => "▲", "failed" => "✕", "unknown" => "?" }.freeze
        NEEDS_YOU = %w[attention failed].freeze

        module_function

        # @param reading [Hash] a fill preview (see {PipelineFill#preview}), or `{unknown: reason}`
        # @return [String] the dry run of the next fill, as a heading and a table
        def fill(reading)
          return unknown(reading) if reading.key?(:unknown)

          rows = reading[:would_start].map { |work| [work[:slug], "would start"] } +
                 reading[:skipped].map { |work| [work[:slug], "skipped: #{work[:reason]}"] }
          "<h2 style=\"margin-top:10px\">Dispatch.Fill dry run: would start #{reading[:would_start].size}#{as_of(reading)}</h2>" \
            "#{table(["Work item", "Result"], rows)}"
        end

        # @param row [Hash] a strip row: `name`, `state`, `count`, `detail`
        # @return [String] the stage, its count, its state and its detail; a stage that needs a
        #   person carries the words the page resolves it with
        def stage(row)
          needs = NEEDS_YOU.include?(row[:state])
          "<div class=\"tilebody#{" clickable" if needs}\" data-tip=\"#{esc(tip(row, needs))}\"#{resolves(row) if needs}>" \
            "<div class=\"name\">#{esc(row[:name])}</div><div class=\"count\">#{esc(row[:count])}</div>" \
            "#{badge(row[:state])}<div class=\"detail\">#{esc(row[:detail])}</div></div>"
        end

        def unknown(reading) = "<p class=\"unknown-note\">unknown: #{esc(reading[:unknown])}</p>"

        def badge(state)
          icon = state == "working" ? "<span class=\"spin\">#{ICON[state]}</span>" : (ICON[state] || "?")
          "<span class=\"badge #{esc(state)}\">#{icon} #{esc(state)}</span>"
        end

        def table(head, rows)
          cells = rows.map { |row| "<tr>#{row.map { |cell| "<td>#{esc(cell)}</td>" }.join}</tr>" }
          "<table><thead><tr>#{head.map { |name| "<th>#{esc(name)}</th>" }.join}</tr></thead><tbody>#{cells.join}</tbody></table>"
        end

        def as_of(reading) = reading[:at] ? " (as of #{esc(reading[:at])})" : ""

        def tip(row, needs) = "#{row[:name]}: #{row[:detail]}#{" (click to resolve)" if needs}"

        def resolves(row) = " data-resolve=\"#{esc(row[:name])}\" data-detail=\"#{esc(row[:detail])}\""

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

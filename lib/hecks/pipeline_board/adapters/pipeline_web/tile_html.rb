# frozen_string_literal: true

require "cgi"
require_relative "../pipeline_stages/integration_runs"
require_relative "../pipeline_stages/fill_age"

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

        # The Integration stage and, under it, two tables: each stored stage with how many runs it
        # holds and the time since any of them last moved, then the runs listed, each with the
        # stage the saga stored for it and the time since its last recorded event. The stage of
        # runs parked for a person is marked by an icon and words, not by colour. The tile offers
        # nothing to click.
        #
        # @param row [Hash] the strip's Integration row with its `reading` (see {IntegrationRuns})
        # @return [String] the stage's body and a table of its runs
        def integration(row)
          reading = row[:reading].to_h
          "#{plain_stage(row)}#{stage_table(reading)}#{run_table(reading)}"
        end

        # @param reading [Hash] the integration reading
        # @return [String] one row per stored stage: the stage, its runs and their last event
        def stage_table(reading)
          quiet = reading[:quiet_minutes]
          rows = reading[:by_stage].to_a.map { |line| [stage_word(line), line[:count], last_event(line, quiet)] }
          listing(%w[Stage Runs], rows)
        end

        # @param reading [Hash] the integration reading
        # @return [String] one row per listed run: its commit, its stage and its last event
        def run_table(reading)
          rows = reading[:runs].to_a.map { |run| [run[:short], stage_word(run), last_event(run, reading[:quiet_minutes])] }
          listing(%w[Run Stage], rows)
        end

        # @param line [Hash] a run or a stage line with its `minutes`
        # @param quiet [Integer, nil] the minutes the log's tail reaches back
        # @return [String] the time since its last event, in words
        def last_event(line, quiet) = IntegrationRuns.since(line[:minutes], quiet)

        # @param head [Array<String>] the first columns' names; the last is always the last event
        # @param rows [Array<Array>] the table's rows
        # @return [String] the table, or nothing when it has no row
        def listing(head, rows) = rows.empty? ? "" : table([*head, "Last event"], rows)

        # @param line [Hash] a run or a stage line: `stage` and `parked`
        # @return [String] the stage as the saga stored it; the parked one with an icon and words
        def stage_word(line) = line[:parked] ? "#{ICON["failed"]} needs you (#{line[:stage]})" : line[:stage].to_s

        # @param row [Hash] a strip row
        # @return [String] the stage, its count, its state and its detail, with nothing to click
        def plain_stage(row)
          "<div class=\"tilebody\" data-tip=\"#{esc(tip(row, false))}\">" \
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

        def as_of(reading)
          return "" unless reading[:at]

          " (as of #{esc(reading[:at])}#{"; stale: #{FillAge.note(reading)}" if FillAge.stale?(reading)})"
        end

        def tip(row, needs) = "#{row[:name]}: #{row[:detail]}#{" (click to resolve)" if needs}"

        def resolves(row) = " data-resolve=\"#{esc(row[:name])}\" data-detail=\"#{esc(row[:detail])}\""

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

# frozen_string_literal: true

require "cgi"
require_relative "plan_item"

module Hecks
  module Adapters
    module PipelineBoard
      # One epic on the planning page: a closed row that reads at a glance (its title, the outcome
      # it is for, a track with one cell for each item coloured by lane, and how many are done),
      # which opens onto its items. Every epic is drawn closed, so the page is one screen of rows.
      module PlanEpic
        module_function

        # @param epic [Hash] an epic of {PlanReading}
        # @return [String] the epic's HTML
        def draw(epic)
          "<details class=\"epic\" data-epic=\"#{esc(epic[:epic])}\">" \
            "<summary>#{name(epic[:title], epic[:outcome])}#{adrs(epic[:decisions])}#{track(epic[:done].to_i, epic[:items])}" \
            "<span class=\"counts\">#{counts(epic)}</span></summary>#{next_line(epic)}#{items(epic[:items])}" \
            "#{closed(epic)}</details>"
        end

        # @param epic [Hash] an epic of {PlanReading}, with its `closed` items
        # @return [String] the epic's finished and dropped items, under its open ones, so an
        #   opened epic lists all the work it holds; nothing when it has none
        def closed(epic)
          rows = Array(epic[:closed])
          return "" if rows.empty?

          "<div class=\"items over\"><p class=\"over-head\">Finished and dropped (#{rows.size})</p>" \
            "#{rows.map { |row| closed_row(row, epic[:epic]) }.join}</div>"
        end

        # One item that is over: its title and key, and how it ended.
        def closed_row(row, epic)
          lane = row[:status] == "done" ? "done" : "dropped"
          marks = "data-status=\"#{esc(row[:status])}\" data-epic=\"#{esc(epic)}\" data-priority=\"\" data-area=\"\""
          "<div class=\"item closed\" #{marks}><i class=\"cell c-#{lane}\"></i>" \
            "<span class=\"what\">#{esc(row[:title])} <code>#{esc(row[:slug])}</code></span> " \
            "<span class=\"chip k-#{lane}\">#{esc(row[:status])}</span></div>"
        end

        # @param data [Hash] the items in no epic: `count` and `items`
        # @return [String] those items drawn as one closed row, or nothing when there are none
        def loose(data)
          return "" if data[:count].zero?

          "<details class=\"epic none\" data-epic=\"\"><summary>" \
            "#{name("no epic (#{data[:count]})", "Items that belong to no epic yet")}#{track(0, data[:items])}" \
            "<span class=\"counts\"></span></summary>#{items(data[:items])}</details>"
        end

        # The decisions the epic carries out, as small tags after its name; nothing when it names
        # none.
        def adrs(decisions)
          list = Array(decisions)
          return "" if list.empty?

          tags = list.first(3).map { |id| "ADR #{esc(id)}" }.join(" ")
          "<span class=\"adr\" title=\"Decisions this epic carries out\">#{tags}</span>"
        end

        # The epic's title and its outcome; the outcome is shown short, and whole as its hover.
        def name(title, outcome)
          said = esc(outcome)
          "<span class=\"name\"><b>#{esc(title)}</b><span class=\"outcome\" title=\"#{said}\">#{said}</span></span>"
        end

        # One cell for each finished item, then one for each open item in reading order.
        def track(done, rows)
          cells = Array.new(done) { cell("done", "done") } + rows.map { |row| cell(row[:lane], "#{row[:slug]}: #{row[:title]}") }
          "<span class=\"track\">#{cells.join}</span>"
        end

        def cell(lane, tip) = "<i class=\"cell c-#{esc(lane)}\" title=\"#{esc(tip)}\"></i>"

        def counts(epic)
          done = epic[:done].to_i
          dropped = epic[:dropped].to_i.positive? ? ", #{epic[:dropped]} dropped" : ""
          "#{done} of #{done + epic[:open]} done#{dropped}"
        end

        def next_line(epic) = epic[:next] ? "<p class=\"next\">Starts next: #{esc(epic[:next][:title])}</p>" : ""

        def items(rows) = "<div class=\"items\">#{rows.map { |row| PlanItem.draw(row) }.join}</div>"

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

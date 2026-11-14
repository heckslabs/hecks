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
            "<summary>#{name(epic[:title], epic[:outcome])}#{track(epic[:done].to_i, epic[:items])}" \
            "<span class=\"counts\">#{counts(epic)}</span></summary>#{next_line(epic)}#{items(epic[:items])}</details>"
        end

        # @param data [Hash] the items in no epic: `count` and `items`
        # @return [String] those items drawn as one closed row, or nothing when there are none
        def loose(data)
          return "" if data[:count].zero?

          "<details class=\"epic none\" data-epic=\"\"><summary>" \
            "#{name("no epic (#{data[:count]})", "Items that belong to no epic yet")}#{track(0, data[:items])}" \
            "<span class=\"counts\"></span></summary>#{items(data[:items])}</details>"
        end

        def name(title, outcome)
          "<span class=\"name\"><b>#{esc(title)}</b><span class=\"outcome\">#{esc(outcome)}</span></span>"
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

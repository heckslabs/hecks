# frozen_string_literal: true

require "cgi"
require_relative "plan_item"
require_relative "plan_epic"
require_relative "plan_overview"
require_relative "plan_flow_html"

module Hecks
  module Adapters
    module PipelineBoard
      # The planning page's tile as HTML: the overview that is read at a glance, then the epics as
      # closed rows under the lane they sit in (most urgent lane first), then the items in no epic.
      # Filters on the page hide rows by their `data-` attributes, so a redraw keeps them.
      module PlanHtml
        # The heading each lane of epics is drawn under.
        LANES = { "running" => "Running now", "now" => "Now", "next" => "Next", "later" => "Later",
                  "unset" => "Not prioritised", "done" => "Finished" }.freeze

        module_function

        # @param reading [Hash] see {PlanReading.build}, or `{unknown: reason}`
        # @return [String] the tile's HTML
        def draw(reading)
          return TileHtml.unknown(reading) if reading.key?(:unknown)

          top = "#{PlanOverview.draw(reading)}#{PlanFlowHtml.draw(reading[:flow])}"
          "#{top}#{lanes(reading[:epics])}#{no_epic(reading[:no_epic])}"
        end

        def lanes(epics) = epics.group_by { |epic| epic[:lane] }.map { |name, list| lane(name, list) }.join

        def lane(name, list)
          open = list.sum { |epic| epic[:open] }
          "<section class=\"lane\" data-lane=\"#{esc(name)}\"><h2>#{esc(LANES.fetch(name, name))} " \
            "<span class=\"counts\">#{plural(list.size, "epic")}, #{plural(open, "open item")}</span></h2>" \
            "#{list.map { |epic| PlanEpic.draw(epic) }.join}</section>"
        end

        def no_epic(data)
          drawn = PlanEpic.loose(data)
          drawn.empty? ? "" : "<section class=\"lane\" data-lane=\"none\">#{drawn}</section>"
        end

        def plural(count, word) = "#{count} #{word}#{"s" unless count == 1}"

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

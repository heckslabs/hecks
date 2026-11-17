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

        # How many names a shut lane's header lists before it counts the rest.
        PEEK = 3

        # A lane is a panel drawn shut, like the home page's: its heading, its counts and the
        # first epics by name.
        def lane(name, list)
          panel(name, LANES.fetch(name, name), pills(list), list.map { |epic| epic[:title] },
                list.map { |epic| PlanEpic.draw(epic) }.join)
        end

        # A lane's counts: its epics and open items, and its finished items when it has any.
        def pills(list)
          open = list.sum { |epic| epic[:open] }
          done = list.sum { |epic| epic[:done].to_i }
          counts = "<span class=\"counts\">#{plural(list.size, "epic")}, #{plural(open, "open item")}</span>"
          done.positive? ? "#{counts}<span class=\"ok\"><b>#{done}</b> done</span>" : counts
        end

        def no_epic(data)
          drawn = PlanEpic.loose(data)
          return "" if drawn.empty?

          pills = "<span class=\"counts\">#{plural(data[:count], "open item")} in no epic</span>"
          panel("none", "No epic", pills, Array(data[:items]).map { |row| row[:title] }, drawn)
        end

        def panel(name, title, pills, names, rows)
          "<details class=\"lane\" data-lane=\"#{esc(name)}\"><summary><h2>#{esc(title)}</h2>" \
            "<span class=\"sum\">#{pills}#{peek(names)}</span></summary>#{rows}</details>"
        end

        # The first few names, so a shut lane says what is in it: "A, B, C and 4 more".
        def peek(names)
          return "" if names.empty?

          more = names.size - PEEK
          said = names.first(PEEK).map { |one| esc(one) }.join(", ")
          "<span class=\"peek\">#{said}#{" and #{more} more" if more.positive?}</span>"
        end

        def plural(count, word) = "#{count} #{word}#{"s" unless count == 1}"

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

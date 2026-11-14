# frozen_string_literal: true

require "cgi"

module Hecks
  module Adapters
    module PipelineBoard
      # The planning page's flow card: one sentence on whether the plan grows or shrinks, then a
      # pair of bars for each of the last days, the items planned beside the items closed
      # (finished, with the dropped ones stacked on them). Nothing is drawn when the plan's events
      # were not read.
      module PlanFlowHtml
        module_function

        # @param flow [Hash, nil] see {PlanFlow.build}
        # @return [String] the card's HTML, or nothing
        def draw(flow)
          return "" unless flow.is_a?(Hash) && flow[:days]

          "<div class=\"flow\"><h3>Planned and closed each day</h3><p class=\"flowline\">#{sentence(flow)}</p>" \
            "#{bars(flow[:days])}#{key}</div>"
        end

        def sentence(flow)
          rates = flow[:rates]
          "<b>#{rates[:planned]}</b> planned a day, <b>#{rates[:finished]}</b> finished and <b>#{rates[:dropped]}</b> " \
            "dropped, over the #{flow[:days].size - 1} days before today. #{direction(flow)}"
        end

        # Which way the plan is going, and how long the open items take at that pace.
        def direction(flow)
          net = flow[:net]
          return "<span class=\"grows\">The plan grows by #{net} items a day.</span>" if net.positive?
          return "<span>The plan holds steady.</span>" if net.zero?

          "<span class=\"shrinks\">The plan shrinks by #{-net} a day: #{flow[:open]} open items clear in about " \
            "#{flow[:clears_in]} days.</span>"
        end

        def bars(days)
          top = [days.map { |day| [day[:planned], day[:finished] + day[:dropped]].max }.max, 1].max
          drawn = days.each_with_index.map { |day, index| pair(day, top, today: index == days.size - 1) }
          "<div class=\"flowbars\">#{drawn.join}</div>"
        end

        def pair(day, top, today:)
          tip = "#{day[:label]}: #{day[:planned]} planned, #{day[:finished]} finished, #{day[:dropped]} dropped"
          "<div class=\"fday#{" today" if today}\" title=\"#{esc(tip)}\"><div class=\"pair\">" \
            "#{column("p", day[:planned], [[day[:planned], "planned"]], top)}" \
            "#{column("c", day[:finished], [[day[:dropped], "dropped"], [day[:finished], "finished"]], top)}</div>" \
            "<span>#{today ? "today" : esc(day[:label])}</span></div>"
        end

        # One column: its number, then a segment for each part, the first on top.
        def column(name, number, parts, top)
          segments = parts.map { |count, word| "<i class=\"#{word}\" style=\"height:#{(100.0 * count / top).round(1)}%\"></i>" }
          "<div class=\"col #{name}\"><em>#{number}</em>#{segments.join}</div>"
        end

        def key
          "<ul class=\"key\"><li><i class=\"cell planned\"></i>planned</li><li><i class=\"cell finished\"></i>finished</li>" \
            "<li><i class=\"cell dropped\"></i>dropped</li></ul>"
        end

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

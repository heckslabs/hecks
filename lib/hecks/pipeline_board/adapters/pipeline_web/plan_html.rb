# frozen_string_literal: true

require "cgi"
require_relative "plan_item"

module Hecks
  module Adapters
    module PipelineBoard
      # The planning page's tile as HTML: the strip that answers four questions, then the epics
      # (open first) and the items in no epic, each grouped by the area its Work items declare.
      # Filters on the page hide rows by their `data-` attributes, so a redraw keeps them.
      module PlanHtml
        module_function

        # @param reading [Hash] see {PlanReading.build}, or `{unknown: reason}`
        # @return [String] the tile's HTML
        def draw(reading)
          return TileHtml.unknown(reading) if reading.key?(:unknown)

          "#{strip(reading[:strip])}#{reading[:epics].map { |epic| epic(epic) }.join}#{no_epic(reading[:no_epic])}"
        end

        def strip(data)
          "<div class=\"strip4\">#{running(data[:running])}#{upnext(data)}#{landing(data[:landing])}#{owner(data[:owner])}</div>"
        end

        def running(rows)
          list = rows.map { |row| "#{esc(row[:slug])} (#{PlanItem.session_link(row)})" }
          card("Running now (#{rows.size})", list.empty? ? ["nothing"] : list, raw: true)
        end

        def upnext(data)
          held = data[:held].map { |row| "#{esc(row[:slug])} held: #{esc(row[:reason])}" }
          card("Up next (#{data[:next].size})", data[:next].map { |row| esc(row[:slug]) } + held, raw: true)
        end

        def landing(train)
          card("Landing now", ["#{esc(train[:count])} #{esc(train[:state])}: #{esc(train[:detail])}"], raw: true)
        end

        def owner(sessions)
          return card("Needs you: nothing", []) if sessions.empty?

          named = sessions.map { |s| esc(s[:work_item].to_s.empty? ? s[:id] : s[:work_item]) }
          card("#{sessions.size} waiting on you", named, raw: true)
        end

        def card(title, lines, raw: false)
          body = lines.map { |line| "<li>#{raw ? line : esc(line)}</li>" }.join
          "<div class=\"card4\"><h3>#{esc(title)}</h3><ul>#{body}</ul></div>"
        end

        def epic(data)
          "<details class=\"epic\" open data-epic=\"#{esc(data[:epic])}\"><summary><b>#{esc(data[:title])}</b> " \
            "<span class=\"counts\">#{counts(data)}</span></summary><p class=\"outcome\">#{esc(data[:outcome])}</p>" \
            "#{next_line(data)}#{groups(data[:groups])}</details>"
        end

        def counts(data)
          "#{data[:done]} done, #{data[:dropped]} dropped, #{data[:open]} open; running #{data[:running].size}"
        end

        def next_line(data)
          data[:next] ? "<p class=\"next\">next planned: #{esc(data[:next][:slug])}</p>" : ""
        end

        def no_epic(data)
          "<details class=\"epic none\" open data-epic=\"\"><summary><b>no epic (#{data[:count]})</b></summary>" \
            "#{groups(data[:groups])}</details>"
        end

        def groups(list)
          list.map do |area, rows|
            "<div class=\"group\" data-area=\"#{esc(area)}\"><h4>#{esc(area)} (#{rows.size})</h4>" \
              "#{rows.map { |row| PlanItem.draw(row) }.join}</div>"
          end.join
        end

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

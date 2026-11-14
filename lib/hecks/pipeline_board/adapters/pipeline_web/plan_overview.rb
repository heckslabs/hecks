# frozen_string_literal: true

require "cgi"
require_relative "plan_item"

module Hecks
  module Adapters
    module PipelineBoard
      # The top of the planning page, read at a glance: one sentence saying how much is open and
      # done, a bar of every item by lane with its key, and the four answers the owner asks for
      # (what runs, what starts next, what lands, what waits on them).
      module PlanOverview
        # The lanes in the order the bar draws them, each with the word the key gives it.
        WORDS = { "done" => "done", "running" => "running", "now" => "now", "next" => "next", "later" => "later",
                  "unset" => "not prioritised" }.freeze

        module_function

        # @param reading [Hash] see {PlanReading.build}
        # @return [String] the overview's HTML
        def draw(reading)
          sum = reading[:summary]
          "<div class=\"overview\"><p class=\"headline\">#{headline(sum)}</p>#{bar(sum[:lanes])}#{key(sum[:lanes])}" \
            "#{strip(reading[:strip])}</div>"
        end

        def headline(sum)
          "<b>#{sum[:open]}</b> #{sum[:open] == 1 ? "item" : "items"} open in #{sum[:epics]} " \
            "#{sum[:epics] == 1 ? "epic" : "epics"}<span class=\"sofar\">#{sum[:done]} done so far</span>"
        end

        def bar(lanes)
          parts = shown(lanes).map { |lane, count| part(lane, count) }
          "<div class=\"bar\" role=\"img\" aria-label=\"Items by lane\">#{parts.join}</div>"
        end

        def part(lane, count) = "<i class=\"c-#{lane}\" style=\"flex:#{count}\" title=\"#{count} #{WORDS[lane]}\"></i>"

        def key(lanes)
          parts = shown(lanes).map { |lane, count| "<li><i class=\"cell c-#{lane}\"></i>#{count} #{WORDS[lane]}</li>" }
          "<ul class=\"key\">#{parts.join}</ul>"
        end

        def shown(lanes) = WORDS.keys.map { |lane| [lane, lanes[lane].to_i] }.reject { |_, count| count.zero? }

        def strip(data)
          "<div class=\"strip4\">#{running(data[:running])}#{upnext(data)}#{landing(data[:landing])}#{owner(data[:owner])}</div>"
        end

        def running(rows)
          list = rows.map { |row| "#{esc(row[:title])} <span class=\"facts\">#{PlanItem.session_link(row)}</span>" }
          card("Running now (#{rows.size})", list.empty? ? ["nothing is running"] : list)
        end

        def upnext(data)
          held = data[:held].map { |row| "#{esc(row[:slug])} <span class=\"facts\">held: #{esc(row[:reason])}</span>" }
          lines = data[:next].map { |row| esc(row[:slug]) } + held
          card("Up next (#{data[:next].size})", lines.empty? ? ["nothing is queued to start"] : lines)
        end

        def landing(train)
          card("Landing now", ["#{esc(train[:count])} #{esc(train[:state])} <span class=\"facts\">#{esc(train[:detail])}</span>"])
        end

        def owner(sessions)
          return card("Needs you: nothing", ["no session is waiting on an answer"]) if sessions.empty?

          named = sessions.map { |s| esc(s[:work_item].to_s.empty? ? s[:id] : s[:work_item]) }
          card("#{sessions.size} waiting on you", named, mark: " you")
        end

        # @param lines [Array<String>] the card's lines, already escaped
        def card(title, lines, mark: "")
          "<div class=\"card4#{mark}\"><h3>#{esc(title)}</h3><ul>#{lines.map { |line| "<li>#{line}</li>" }.join}</ul></div>"
        end

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end

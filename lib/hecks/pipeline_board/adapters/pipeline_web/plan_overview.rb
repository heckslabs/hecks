# frozen_string_literal: true

require "cgi"

module Hecks
  module Adapters
    module PipelineBoard
      # The top of the planning page, read at a glance: one sentence saying how much is open and
      # done, a bar of every item by lane with its key, and the four answers the owner asks for
      # (what runs, what starts next, what lands, what waits on them).
      module PlanOverview
        # The lanes in the order the bar draws them, each with the word the key gives it.
        WORDS = { "done" => "done", "running" => "running", "expedite" => "expedited", "now" => "now", "next" => "next",
                  "later" => "later", "unset" => "not prioritised" }.freeze

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
          cards = [running(data[:running]), upnext(data), landing(data[:landing]), owner(data[:owner], Array(data[:help]))]
          "<div class=\"strip4\">#{cards.join}</div>"
        end

        # The count of running items, linking to the Running now panel that holds them.
        def running(rows)
          said = "<a href=\"#running\">#{rows.size} #{rows.size == 1 ? "item" : "items"} running</a>"
          card("Running now (#{rows.size})", [rows.empty? ? "nothing is running" : said])
        end

        # How many queued items the card names; the rest are counted, never listed.
        UPNEXT_SHOWN = 3

        def upnext(data)
          lines = queued_lines(data[:next]) + held_lines(data[:held])
          card("Up next (#{data[:next].size})", lines.empty? ? ["nothing is queued to start"] : lines)
        end

        # The first few queued items by name, then how many more there are.
        def queued_lines(rows)
          more = rows.size - UPNEXT_SHOWN
          named = rows.first(UPNEXT_SHOWN).map { |row| esc(row[:slug]) }
          more.positive? ? named + ["and #{more} more"] : named
        end

        # One line per distinct reason with a count, so 300 held items do not print 300 lines.
        def held_lines(rows)
          rows.group_by { |row| row[:reason] }.map do |reason, group|
            "#{group.size} held <span class=\"facts\">#{esc(reason)}</span>"
          end
        end

        # Another project's plan has no train of the board's to show: its card says so.
        def landing(train)
          return card("Landing now", ["not read for this project"]) unless train

          card("Landing now", ["#{esc(train[:count])} #{esc(train[:state])} <span class=\"facts\">#{esc(train[:detail])}</span>"])
        end

        # The sessions waiting on an answer, then the calls for help the owner is shown, one line
        # each; the card's number counts both.
        def owner(sessions, help)
          named = sessions.map { |s| esc(s[:work_item].to_s.empty? ? s[:id] : s[:work_item]) }
          lines = named + help.map { |row| esc(row[:line]) }
          return card("Needs you: nothing", ["no session is waiting on an answer"]) if lines.empty?

          card("#{lines.size} waiting on you", lines, mark: " you")
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

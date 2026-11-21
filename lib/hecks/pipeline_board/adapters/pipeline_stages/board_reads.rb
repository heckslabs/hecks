# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's newer readings as the `Snapshot`'s rows: Signalbox's one signal, the fill's
      # skips in the words of the side deciding, the red episodes, the outcome measures, the ranked
      # epics and what holds boarding. The `SignalSays`, `FillSide` and `OutcomeState` rows give
      # the words and states; this module only shapes what the readers answered. A section that
      # could not be read is one row in state `unknown` with its reason, said once.
      module BoardReads
        # A fact nobody asked for is unread.
        NOT_READ = { unknown: "not read" }.freeze
        SECTIONS = %i[signal fill episodes measures epics holds].freeze

        module_function

        # @param facts [Hash] `signal`, `side`, `fill`, `episodes`, `measures`, `epics` and `holds`,
        #   each as read or `{unknown: reason}`
        # @param at [String] when they were read
        # @return [Hash] the `Snapshot` keys these readings fill
        def build(given, at)
          facts = SECTIONS.to_h { |name| [name, NOT_READ] }.merge(given)
          { signal: signal(facts[:signal], at), deciding: facts[:side].to_s, fill_why: fill_why(facts),
            red_episodes: red_episodes(facts[:episodes]), measures: outcomes(facts[:measures], at, :measure),
            epics: outcomes(facts[:epics], at, :epic), holds: holds(facts[:holds], at) }
        end

        # @return [Hash] the one `Reading` for Signalbox's signal
        def signal(read, at)
          return unread("signal", "Signal", read, at) if unknown?(read)

          row = Rules.rows("SignalSays").find { |held| held[:band] == read[:band].to_s } || { says: "", state: "unknown" }
          reading({ key: "signal", label: "Signal", value: read[:band], state: row[:state], note: said(row, read) }, at)
        end

        def said(row, read) = format(row[:says], load: read[:load], mark: read[:mark] || "?", since: read[:since].to_s)

        # @return [Array<Hash>] one `FillWhy` for each item the fill did not start
        def fill_why(facts)
          fill = facts[:fill]
          return [{ work: "fill", reason: "unknown: #{fill[:unknown]}", side: "" }] if unknown?(fill)

          side = Rules.rows("FillSide").find { |held| held[:side] == facts[:side].to_s }
          Array(fill[:skipped]).map { |held| why(held, side) }
        end

        def why(held, side)
          words = side ? format(side[:says], why: held[:reason]) : held[:reason].to_s
          { work: held[:slug].to_s, reason: words, side: side ? side[:side] : "" }
        end

        # @return [Array<Hash>] one `RedEpisodeLine` each, as the episodes were read
        def red_episodes(read)
          return [line(ending: "unknown", line: "unknown: #{read[:unknown]}")] if unknown?(read)

          read.map { |episode| episode_line(episode) }
        end

        def episode_line(episode)
          began = episode[:began].to_s
          ending = episode[:ending].to_s.empty? ? "standing" : episode[:ending].to_s
          said = "#{began}, #{episode[:minutes]} min, culprit #{episode[:culprit]}, #{ending}"
          line(began: began, minutes: episode[:minutes].to_i, culprit: episode[:culprit].to_s, work: episode[:work].to_s,
               ending: ending, line: said)
        end

        def line(given) = { began: "", minutes: 0, culprit: "", work: "", ending: "standing", line: "" }.merge(given)

        # @return [Array<Hash>] a `Reading` for each measure or epic by its `outcome`
        def outcomes(read, at, key)
          return [unread(key.to_s, key.to_s.capitalize, read, at)] if unknown?(read)

          read.map { |item| outcome(item, at, key) }
        end

        def outcome(item, at, key)
          found = Rules.rows("OutcomeState").find { |held| held[:outcome] == item[:outcome].to_s }
          reading({ key: "#{key}_#{item[:name]}", label: item[:name], value: item[:value],
                    state: found ? found[:state] : "unknown", note: item[:note] }, at)
        end

        # @return [Array<Hash>] a `Reading` for each hold on boarding
        def holds(read, at)
          return [unread("hold", "Boarding", read, at)] if unknown?(read)

          read.map do |item|
            reading({ key: "hold_#{item[:name]}", label: item[:name], value: item[:value],
                      state: item[:state] || "ok", note: item[:note] }, at)
          end
        end

        def unknown?(read) = !read.is_a?(Array) && !(read.is_a?(Hash) && !read.key?(:unknown))

        def unread(key, label, read, at)
          why = read.is_a?(Hash) ? read[:unknown] : "not read"
          reading({ key: key, label: label, state: "unknown", note: "unknown: #{why}" }, at)
        end

        # @param given [Hash] `key`, `label`, `value`, `state` and `note`
        def reading(given, at)
          shown = given.merge(label: given[:label].to_s, value: given[:value].to_s, note: given[:note].to_s)
          { unit: "", since: "", link: "", source: "Pipeline", fresh_at: at }.merge(shown)
        end
      end
    end
  end
end

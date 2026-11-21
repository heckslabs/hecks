# frozen_string_literal: true

require_relative "price_table"
require_relative "session_role"

module Hecks
  module Adapters
    class Metering
      # Rolls the usage rows up: tokens used per session, role, Work item and day, each with its
      # input, output and cache split and its dollars from {PriceTable}, and the tokens saved, each
      # line labelled with how it is counted. The saving the outside gives no record of is named
      # `not measured`, never guessed.
      class TokenReport
        SPLIT = %i[input output cache_creation cache_read].freeze

        LABELS = {
          prompt_cache:  "prompt cache: cache reads billed at a tenth of fresh input; saved = cache_read x (1 - 0.1)",
          model_routing: "model routing: Sonnet and Haiku tokens priced at Opus, less what they cost"
        }.freeze

        NOT_MEASURED = {
          hecks_door:      "Hecks door: no record names the files a door answer stood in for",
          work_not_redone: "work not redone: no record of a run avoided by a revert or an early refusal"
        }.freeze

        # @param rows [Array<Hash>] usage rows, as {TokenTranscripts#call} answers
        # @param runs [Hash{String => Hash}] each session's AgentRun, by session id
        def initialize(rows, runs)
          @rows = rows
          @runs = runs
        end

        # @return [Hash] `by_session`, `by_role`, `by_item` and `by_day` (arrays of rollups),
        #   `total`, `saved` (each line's `label`, `tokens` and `dollars`) and `not_measured`
        def facts
          { by_session: roll(:session), by_role: roll(:role), by_item: roll(:item), by_day: roll(:day),
            total: total(@rows), saved: saved(@rows), not_measured: NOT_MEASURED.values }
        end

        private

        def roll(key)
          groups = tagged.group_by { |row| row[key] }.reject { |name, _| name.to_s.empty? }
          groups.map { |name, rows| { key.to_s => name, **total(rows), saved: saved(rows) } }.sort_by { |line| line[key.to_s] }
        end

        # Each usage row with the role and Work item its session's run names.
        def tagged
          @tagged ||= @rows.map { |row| row.merge(role: role(row), item: item(row)) }
        end

        def total(rows)
          counts = SPLIT.to_h { |name| [name, rows.sum { |row| row[name] }] }
          { **counts, tokens: counts.values.sum, dollars: rows.sum { |row| PriceTable.dollars(row[:model], row) }.round(4) }
        end

        def saved(rows)
          [cache_line(rows), routing_line(rows)]
        end

        def cache_line(rows)
          read = rows.sum { |row| row[:cache_read] }
          fresh = rows.sum { |row| fresh_cost(row) }
          { label: LABELS[:prompt_cache], tokens: (read * (1 - PriceTable::CACHE_READ_RATIO)).round,
            dollars: (fresh * (1 - PriceTable::CACHE_READ_RATIO)).round(4) }
        end

        def fresh_cost(row)
          PriceTable.dollars(row[:model], { **blank, input: row[:cache_read] })
        end

        def routing_line(rows)
          routed = rows.reject { |row| PriceTable.family(row[:model]) == PriceTable::DEAREST }
          dearer = routed.sum { |row| PriceTable.dollars(row[:model], row, as: PriceTable::DEAREST) }
          own = routed.sum { |row| PriceTable.dollars(row[:model], row) }
          { label: LABELS[:model_routing], tokens: total(routed)[:tokens], dollars: (dearer - own).round(4) }
        end

        def blank = SPLIT.to_h { |name| [name, 0] }

        def role(row)
          run = @runs[row[:session]]
          run ? SessionRole.of({}, run) : "unrun"
        end

        def item(row)
          run = @runs[row[:session]]
          return "" unless run

          run[:work].to_s.empty? ? run[:run].to_s : run[:work].to_s
        end
      end
    end
  end
end

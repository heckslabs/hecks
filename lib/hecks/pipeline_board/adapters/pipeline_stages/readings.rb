# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The strip's rows and the metric tiles as the bluebook's `Stage` and `Reading` rows: one
      # key each, the count or number as the value, the detail line as the note. It shapes only;
      # every state word was decided by a `Verdict` row before the row reached it.
      module Readings
        # The port each reading came from, by its key; the rest are composed by `Pipeline`.
        SOURCES = { "work_items" => "Tickets", "sessions" => "Jobs", "local_main" => "Git", "train" => "Git",
                    "promote" => "Git", "red_flag" => "Git", "ahead" => "Git", "ci" => "GitHub", "release" => "GitHub",
                    "success" => "GitHub", "wall" => "GitHub", "failed_head" => "GitHub", "red" => "GitHub",
                    "release_age" => "GitHub", "open_prs" => "GitHub", "working" => "Jobs", "throughput" => "Journal",
                    "health" => "Journal", "stopped_runs" => "Tickets", "overdue_for_you" => "Tickets" }.freeze

        # The tiles whose page id is taken by a stage: each gets a key of its own.
        RENAMED = { "release" => "release_age", "ci" => "ci_runs" }.freeze

        # A run of anything a key does not hold: a key is lower-case letters, digits and `_`.
        NOT_A_KEY_LETTER = /[^a-z0-9]+/

        module_function

        # @param rows [Array<Hash>] the strip's rows (`name`, `state`, `count`, `detail`)
        # @param at [String] when they were read
        # @return [Array<Hash>] one `Stage` row each, in the strip's order
        def stages(rows, at)
          rows.each_with_index.map { |row, index| stage(row, index + 1, at) }
        end

        # @param tiles [Array<Hash>] the metric tiles (`id`, `label`, `value`, `unit`, `state`,
        #   `detail`)
        # @param at [String] when they were read
        # @return [Array<Hash>] one `Reading` row each
        def tiles(tiles, at) = tiles.map { |tile| reading(tile, at) }

        # @return [Hash] one `Stage` row
        def stage(row, order, at)
          key = key_of(row[:name])
          { key: key, label: row[:name].to_s, value: row[:count].to_s, unit: "", state: row[:state].to_s,
            note: row[:detail].to_s, order: order }.merge(read(key, at))
        end

        # @return [Hash] one `Reading` row
        def reading(tile, at)
          key = RENAMED.fetch(tile[:id].to_s, tile[:id].to_s)
          said = tile.slice(:label, :value, :unit, :state).transform_values(&:to_s)
          { key: key, note: tile[:detail].to_s }.merge(said, read(key, at))
        end

        # @return [Hash] where and when a key's reading was read; the board holds no `since` or
        #   `link` for one yet
        def read(key, at) = { since: "", link: "", source: source_of(key), fresh_at: at }

        # @return [String] a stage's name as a key: `Local main` is `local_main`
        def key_of(name) = name.to_s.downcase.gsub(NOT_A_KEY_LETTER, "_")

        # @return [String] the port a key's reading came from
        def source_of(key) = SOURCES.fetch(key, "Pipeline")
      end
    end
  end
end

# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      module Turns
        # The console projection of one `TurnFinished`: a block headed
        # `turn finished: <role> @ <time>`, one line per field the turn carries, the labels and
        # the values aligned in columns. It reads only the event, so the console and the board
        # can never say different things.
        module Block
          LABEL = 10

          module_function

          # @param turn [Hash] a finished turn, string keys
          # @return [String] the boxed block
          def render(turn)
            head = "--- turn finished: #{turn["role"]} @ #{turn["at"]} ---"
            body = FIELDS.flat_map { |field| lines(field, turn[field]) }
            ([head] + body + ["-" * head.length]).join("\n")
          end

          FIELDS = %w[verdict landed main train dispatched filed stuck unpushed links].freeze

          def lines(field, value)
            return [] if blank?(value)

            rows = send("#{field}_rows", value)
            rows.each_with_index.map { |row, i| "#{(i.zero? ? field : "").ljust(LABEL)}#{row}" }
          end

          def blank?(value) = value.nil? || value == "" || value == [] || value == {}

          def verdict_rows(value) = [value.to_s]

          def landed_rows(list) = rows(list).map { |l| "#{short(l["sha"]).ljust(10)}#{l["title"]}" }

          def main_rows(main)
            main = hash(main)
            sync = "#{short(main["origin"])} +#{main["ahead"].to_i} local#{behind(main)}, #{main["clean"] ? "clean" : "dirty"}"
            [sync.ljust(35) + "origin pushed #{main["origin_pushed_h"]} h ago"]
          end

          def behind(main) = main["behind"].to_i.positive? ? ", #{main["behind"]} behind" : ""

          def train_rows(train)
            train = hash(train)
            [(train["open"] ? "PR #{train["open"]}" : "none open").ljust(35) + "next board: #{train["next_board"]}"]
          end

          def dispatched_rows(list)
            [""] + rows(list).map { |d| dispatched_line(d) }
          end

          def dispatched_line(row)
            "#{" " * LABEL}#{row["work"].to_s.ljust(36)}#{row["role"].to_s.ljust(8)}#{short(row["session"], 8).ljust(10)}" \
              "#{row["state"].to_s.ljust(9)}#{row["age_s"].to_i / 60} min"
          end

          def filed_rows(list)
            rows(list).map { |f| [f["key"].to_s.ljust(45), f["kind"], f["step"]].compact.join("  ").rstrip }
          end

          def stuck_rows(list)
            rows(list).map { |s| "#{short(s["since"], 8).ljust(10)}#{s["what"]}   owner: #{s["owner_run"]}" }
          end

          def unpushed_rows(list)
            rows(list).map { |u| "#{u["branch"]}  #{Array(u["commits"]).join(",")}  #{u["note"]}" }
          end

          def links_rows(list) = Array(list).map(&:to_s)

          def rows(list) = Array(list).map { |item| hash(item) }

          def hash(value) = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}

          def short(text, width = 9) = text.to_s[0, width]
        end
      end
    end
  end
end

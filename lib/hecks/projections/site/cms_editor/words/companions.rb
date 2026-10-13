# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        module Words
          # Puts each `EditorCompanion` row among the `related` panels of the aggregate it goes
          # with, as a record of `with` whose key is made from the record's own (`{slug}` is the
          # record's identity). Several rows for one aggregate and label are alternatives: the first
          # whose `when` holds is the one shown.
          module Companions
            # `<attribute> includes <value>` or `<attribute> is <value>`.
            WHEN = /\A(\w+) (includes|is) (\S.*)\z/

            module_function

            # @return [Array<Hash{String => Object}>] the aggregates, with the companions added
            # @raise [Table::Invalid] naming every row the chapters cannot satisfy
            def apply(aggregates, rows)
              problems = []
              found = rows.filter_map { |row| entry(aggregates, row, problems) }
              Words.refuse("EditorCompanion rows", problems)

              aggregates.map do |agg|
                mine = found.select { |host, _| host.equal?(agg) }.map(&:last)
                mine.empty? ? agg : agg.merge("related" => [*agg["related"], *mine])
              end
            end

            # @return [Array(Hash, Hash), nil] the host aggregate and its `related` entry, or nil
            #   with the problem noted
            def entry(aggregates, row, problems)
              host = Marks.find(aggregates, row[:aggregate])
              with = Marks.find(aggregates, row[:with])
              unless host && with
                problems << "#{row[:aggregate]} -> #{row[:with]}: names no such aggregate"
                return nil
              end

              built = build(with, row, problems)
              built && [host, built]
            end

            def build(with, row, problems)
              problem = problem_with(with, row)
              return shape(with, row) unless problem

              problems << problem
              nil
            end

            def problem_with(with, row)
              return "#{row[:with]} has no attribute #{row[:field]}" unless takes?(with, row[:field])
              return nil if row[:when].nil? || WHEN.match?(row[:when])

              "when #{row[:when].inspect} is not `<attribute> is|includes <value>`"
            end

            def shape(with, row)
              { "aggregate" => with["name"], "chapter" => with["chapter"], "field" => with["identity"], "shape" => "text",
                "create" => creating(with), "edit" => editing(with, row[:field]), "key" => row[:key], "attribute" => row[:field],
                "when" => row[:when], "label" => row[:label], "help" => row[:help] }.compact
            end

            def creating(with)
              made = with["commands"].find { |command| command["creates"] && takes?(command, with["identity"]) }
              made&.fetch("name")
            end

            def editing(with, field)
              moves = (with.dig("lifecycle", "transitions") || []).map { |move| move["verb"] }
              changed = with["commands"].find { |command| edits?(command, field, moves) }
              changed&.fetch("name")
            end

            # Whether a command changes `field` of an existing record, and is not a lifecycle move
            # or a destructive one.
            def edits?(command, field, moves)
              return false if command.values_at("creates", "destructive").any? || moves.include?(command["name"])

              takes?(command, field)
            end

            def takes?(holder, name) = holder["attributes"].any? { |attr| attr["name"] == name }
          end
        end
      end
    end
  end
end

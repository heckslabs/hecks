# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        module Words
          # Two kinds of `EditorThing` and `EditorField` row that say something about a record or a state
          # rather than about an input: the rule that says a record has no page of its own on the site
          # (`preview_unless`), and the words for a lifecycle's states.
          module Rules
            # `<attribute> includes|is <value>`, one or several separated by `;`.
            UNLESS = /\A(\w+) (includes|is) (\S.*)\z/

            module_function

            # @param agg [Hash{String => Object}] the aggregate the row is about
            # @param row [Hash{Symbol => Object}] the checked `EditorThing` row
            # @return [Array<String>] what is wrong with the row's `preview_unless`, one line each
            def preview_unless(agg, row)
              return [] if row[:preview_unless].nil?

              names = agg["attributes"].map { |attr| attr["name"] } + [agg.dig("lifecycle", "field")].compact
              row[:preview_unless].split(";").map(&:strip).reject(&:empty?).filter_map { |rule| refused(row, rule, names) }
            end

            # @return [String, nil] what is wrong with one rule of the row, or nil
            def refused(row, rule, names)
              of = "EditorThing #{row[:aggregate]}: preview_unless"
              found = UNLESS.match(rule)
              return "#{of} #{rule.inspect} is not `<attribute> is|includes <value>`" unless found

              "#{of} names no attribute #{found[1].inspect}" unless names.include?(found[1])
            end

            # @return [Boolean] whether a row is about the aggregate's lifecycle field, whose states it words
            def state_row?(agg, row)
              field = agg.dig("lifecycle", "field")
              !field.nil? && row[:attribute] == field && row[:command].to_s.empty?
            end

            # Writes the words a row gives a lifecycle's states (`options: "live=Showing,down=Hidden"`).
            #
            # @return [void]
            def states(agg, row, problems)
              lifecycle = agg["lifecycle"]
              pairs = row[:options].to_s.split(",").map { |item| item.strip.split("=", 2) }
              pairs.each { |state, word| problems.concat(state_problems(lifecycle, row, state, word)) }
              lifecycle["labels"] = pairs.select { |_, word| word }.to_h
            end

            def state_problems(lifecycle, row, state, word)
              known = [lifecycle["default"], *lifecycle["transitions"].flat_map { |move| [*move["from"], move["to"]] }]
              where = "EditorField #{row[:aggregate]}.#{row[:attribute]}: #{state.inspect}"
              [("#{where} is no state of the lifecycle" unless known.include?(state)),
               ("#{where} needs words (state=Words)" if word.to_s.empty?)].compact
            end
          end
        end
      end
    end
  end
end

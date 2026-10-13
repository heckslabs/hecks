# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # Finds the ranges a form can check before it sends anything: an attribute named `ends_*`
        # beside one named `starts_*` with the same rest of the name ends the range that one starts.
        # The end carries `after`, the name of its start, wherever the pair sits: an aggregate's
        # attributes, a command's arguments, or the parts of a value object (the rows of a list).
        # An `EditorField` row's `after` says the same for names the rule does not cover.
        module Ranges
          # The pair of words the rule reads: the start's prefix and the end's.
          START = "starts_"
          FINISH = "ends_"

          module_function

          # @param aggregates [Array<Hash{String => Object}>] the aggregates as `Schema` shapes them
          # @return [Array<Hash{String => Object}>] the same aggregates, each end marked in place
          def apply(aggregates)
            aggregates.each { |agg| lists(agg).each { |attrs| mark(attrs) } }
          end

          # @return [Array<Array<Hash>>] every list of attributes a form is made of
          def lists(agg)
            [agg["attributes"], *agg["commands"].map { |command| command["attributes"] }, *agg["valueObjects"].values]
          end

          # @param attrs [Array<Hash{String => Object}>] one list of attributes
          # @return [void]
          def mark(attrs)
            names = attrs.map { |attr| attr["name"] }
            attrs.each do |attr|
              next unless attr["name"].start_with?(FINISH)

              start = "#{START}#{attr["name"].delete_prefix(FINISH)}"
              attr["after"] = start if names.include?(start)
            end
          end
        end
      end
    end
  end
end

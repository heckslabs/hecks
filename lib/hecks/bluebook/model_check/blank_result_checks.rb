module Hecks
  module Bluebook
    module ModelCheck
      # The check over a command's result text. A command attribute called report, refusal,
      # summary, outcome, reason or text (the Vocabulary's RequiredTextName) says what the command
      # did; when its type holds no presence rule the command accepts a blank one, and a run ends
      # answered with nothing said.
      module BlankResultChecks
        # @param bluebook [Bluebook::Declaration] the assembled bluebook to check
        # @return [Array<Finding>] one :blank_result_type warning per type that a result attribute
        #   names and that has no presence rule, each type once
        def blank_result_findings(bluebook)
          blank_result_pairs(bluebook).map do |aggregate, type|
            Finding.new(kind: :blank_result_type, severity: :warning, subject: "#{aggregate}.#{type}",
                        message: "a command result is typed #{type}, which accepts a blank — " \
                                 "give it `matches: :present` so a result says something")
          end
        end

        # @return [Array<Array(String, String)>] each aggregate and blank-able type pair, once,
        #   leaving out an aggregate that acknowledges a blank result as meaning what it says
        def blank_result_pairs(bluebook)
          held = bluebook.aggregates.reject { |aggregate| Acknowledgements.held?(aggregate, :blank_result_type) }
          held.flat_map { |aggregate| blank_result_types(aggregate) }.uniq
        end

        # @return [Array<Array(String, String)>] the aggregate and type name of each result
        #   attribute whose type lacks a presence rule
        def blank_result_types(aggregate)
          blankable = aggregate.value_objects.select { |value| blankable_value?(value) }.map(&:hecks_name)
          results = aggregate.commands.flat_map(&:attributes).select { |attribute| result_name?(attribute) }
          results.map { |attribute| [aggregate.hecks_name, attribute.type.to_s] }
                 .select { |_, type| blankable.include?(type) }
        end

        # @return [Boolean] whether the attribute's name is one the Vocabulary names a result
        def result_name?(attribute)
          Hecks::Vocabulary.fetch("RequiredTextName").include?(attribute.name.to_s)
        end

        # @return [Boolean] whether the value object is a bare String with no pattern and no
        #   closed set of members, which a blank is never one of
        def blankable_value?(value)
          return false if value.closed_set?

          field = value.attributes.find { |attribute| attribute.name == :value }
          field&.type.to_s == "String" && field.pattern.nil?
        end
      end
    end
  end
end

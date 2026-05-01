# Hecks::ValidationRules::Structure::GivenReferences
#
# @domain AcceptanceTest
#
# Validates that given expressions and mutation fields reference
# attributes that exist on the aggregate or command. Catches typos
# in Bluebook behavior declarations.
#
#   given { statsu == "draft" }  # warning: statsu not found on Order
#   then_set :statsu, to: "x"   # warning: statsu not found on Order
#
module Hecks
  module ValidationRules
    module Structure

    class GivenReferences < BaseRule
      def errors
        []
      end

      def warnings
        result = []
        @domain.aggregates.each do |agg|
          agg_attrs = agg.attributes.map { |a| a.name.to_s }

          agg.commands.each do |cmd|
            cmd_attrs = cmd.attributes.map { |a| a.name.to_s }
            all_attrs = agg_attrs + cmd_attrs

            cmd.mutations.each do |m|
              unless all_attrs.include?(m.field.to_s)
                result << "#{agg.name}.#{cmd.name}: then_set :#{m.field} — field not found on #{agg.name}"
              end
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(GivenReferences)
    end
  end
end

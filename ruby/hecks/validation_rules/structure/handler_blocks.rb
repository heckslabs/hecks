# Hecks::ValidationRules::Structure::HandlerBlocks
#
# @domain AcceptanceTest
#
# Warns when commands use Ruby handler blocks instead of declarative
# given/then_set. Handler blocks are Ruby — they can't be projected
# to other targets. Given/then is pure Bluebook.
#
#   handler do |pizza|     # warning: use given/then_set
#     pizza.status = "x"
#   end
#
#   given { status == "draft" }   # good: pure Bluebook
#   then_set :status, to: "x"    # good: pure Bluebook
#
module Hecks
  module ValidationRules
    module Structure

    class HandlerBlocks < BaseRule
      def errors
        []
      end

      def warnings
        result = []
        @domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            if cmd.handler.is_a?(Proc)
              result << "#{agg.name}.#{cmd.name} uses a Ruby handler block — use given/then_set instead"
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(HandlerBlocks)
    end
  end
end

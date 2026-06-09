# Hecks::ValidationRules::Structure::ForbidCrossAggregateRefs
#
# @domain AcceptanceTest
#
# Forbids a cross-aggregate read in a command given : `Agg(id).field`. A given
# may only read its OWN aggregate's state — the aggregate is the consistency
# boundary, and a synchronous sibling read breaks the DDD/Hexagonal promise
# (replicate the fact via an event/policy instead, never read it synchronously).
#
# The Ruby twin of the Rust validator's forbid_cross_aggregate_refs rule ; the
# error string is byte-identical so the two validators agree.
#
#   given { Sprint(sprint).state == "active" }   # INVALID : cross-aggregate read
#   given { sprint_active == true }              # ok : reads its own state
#
module Hecks
  module ValidationRules
    module Structure

    class ForbidCrossAggregateRefs < BaseRule
      # Match an UpperCamelCase identifier immediately followed by `(...)` then
      # `.` — the `Agg(id).field` cross-aggregate read shape. Captures `Agg(id)`.
      XREF = /([A-Z][A-Za-z0-9_]*\([^)]*\))\./.freeze

      def errors
        result = []
        @domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            cmd.givens.each do |given|
              expr = given.expression.to_s
              if (m = expr.match(XREF))
                result << "#{agg.name}.#{cmd.name} given has a cross-aggregate read `#{m[1]}` — a given may only read its own aggregate's state; replicate the sibling fact via an event/policy"
              end
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(ForbidCrossAggregateRefs)
    end
  end
end

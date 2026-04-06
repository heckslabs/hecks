# Hecks::CLI::DomainInspector::AggregateFormatter::RuleFormatters
#
# Formats constraint and rule elements of an aggregate: validations,
# invariants, and policies. Mixed into AggregateFormatter to keep
# concerns separated.
#
#   include RuleFormatters
#
module Hecks
  class CLI
    class DomainInspector
      class AggregateFormatter
        module RuleFormatters
          private

          def format_validations
            return [] if @agg.validations.empty?
            lines = ["  Validations:"]
            @agg.validations.each do |v|
              rules = v.rules.map { |k, val| "#{k}: #{val}" }.join(", ")
              lines << "    #{v.field}: #{rules}"
            end
            lines << ""
          end

          def format_invariants
            return [] if @agg.invariants.empty?
            lines = ["  Invariants:"]
            @agg.invariants.each do |inv|
              body = Hecks::Utils.block_source(inv.block)
              lines << "    #{inv.message}: #{body}"
            end
            lines << ""
          end

          def format_policies
            return [] if @agg.policies.empty?
            lines = ["  Policies:"]
            @agg.policies.each do |pol|
              lines << format_policy(pol)
            end
            lines << ""
          end

          def format_policy(pol)
            async_note = pol.async ? " [async]" : ""
            if pol.reactive?
              cond = pol.condition ? " when #{Hecks::Utils.block_source(pol.condition)}" : ""
              "    #{pol.name}: #{pol.event_name} -> #{pol.trigger_command}#{async_note}#{cond}"
            else
              body = Hecks::Utils.block_source(pol.block)
              "    #{pol.name}: guard#{async_note} — #{body}"
            end
          end
        end
      end
    end
  end
end

module Hecks
  class DslSerializer
    # Hecks::DslSerializer::RuleSerializer
    #
    # Serializes validations, invariants, scopes, queries, computed attributes,
    # and specifications into DSL lines.
    #
    #   # Mixed into DslSerializer
    #   serialize_invariants(agg.invariants, "    ")
    #
    module RuleSerializer
      def serialize_validations(validations)
        validations.flat_map do |v|
          ["", "    validation :#{v.field}, #{v.rules.inspect}"]
        end
      end

      def serialize_invariants(invariants, indent)
        invariants.flat_map do |inv|
          body = Hecks::Utils.block_source(inv.block)
          ["", "#{indent}invariant \"#{inv.message}\" do",
           "#{indent}  #{body}",
           "#{indent}end"]
        end
      end

      def serialize_scopes(scopes)
        scopes.reject(&:callable?).flat_map do |s|
          formatted = s.conditions.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
          ["", "    scope :#{s.name}, #{formatted}"]
        end
      end

      def serialize_queries(queries)
        queries.flat_map do |q|
          body = Hecks::Utils.block_source(q.block)
          ["", "    query \"#{q.name}\" do",
           "      #{body}",
           "    end"]
        end
      end

      def serialize_computed_attributes(computed_attrs)
        (computed_attrs || []).flat_map do |ca|
          body = Hecks::Utils.block_source(ca.block)
          ["", "    computed :#{ca.name} do",
           "      #{body}",
           "    end"]
        end
      end

      def serialize_specifications(specs)
        specs.flat_map do |spec|
          param_str = spec_param_string(spec)
          body = Hecks::Utils.block_source(spec.block)
          ["", "    specification \"#{spec.name}\" do #{param_str}",
           "      #{body}",
           "    end"]
        end
      end

      private

      def spec_param_string(spec)
        params = spec.block&.parameters&.map { |_, n| n.to_s } || []
        params.empty? ? "|object|" : "|#{params.join(", ")}|"
      end
    end
  end
end

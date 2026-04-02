# Hecks::Generators::Infrastructure::SpecGenerator::ScopeSpec
#
# Generates RSpec specs for aggregate scopes: creates matching and
# non-matching data, invokes the scope, and verifies filtered results.
# Mixed into SpecGenerator.
#
#   gen.generate_scope_spec(scope, aggregate)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module ScopeSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec for a scope defined on an aggregate.
          #
          # @param scope [Hecks::DomainModel::Structure::Scope] the scope IR
          # @param aggregate [Hecks::DomainModel::Structure::Aggregate]
          # @return [String] the complete RSpec file content
          def generate_scope_spec(scope, aggregate)
            safe_agg = domain_constant_name(aggregate.name)
            create_cmd = find_scope_create_cmd(aggregate)
            return nil unless create_cmd

            create_method = derive_scope_method(create_cmd, aggregate)
            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe \"#{safe_agg}.#{scope.name}\" do"
            lines << "  before { @app = Hecks.load(domain, force: true) }"
            lines << ""

            if scope.callable?
              lines.concat(callable_scope_spec(scope, safe_agg, create_cmd, create_method))
            else
              lines.concat(static_scope_spec(scope, safe_agg, create_cmd, create_method))
            end

            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          def static_scope_spec(scope, safe_agg, create_cmd, create_method)
            conditions = scope.conditions
            lines = []

            if conditions.is_a?(Hash) && !conditions.empty?
              field = conditions.keys.first.to_s
              value = conditions.values.first

              lines << "  it \"returns only #{safe_agg}s matching #{field}: #{value.inspect}\" do"
              lines << "    #{safe_agg}.#{create_method}(#{create_args_override(create_cmd, field, value.inspect)})"
              lines << "    #{safe_agg}.#{create_method}(#{create_args_override(create_cmd, field, '"other"')})"
              lines << "    results = #{safe_agg}.#{scope.name}"
              lines << "    expect(results).to be_an(Array)"
              lines << "    expect(results.all? { |r| r.#{field} == #{value.inspect} }).to be true"
              lines << "  end"
            else
              lines << "  it \"returns an Array\" do"
              lines << "    #{safe_agg}.#{create_method}(#{example_args(create_cmd)})"
              lines << "    results = #{safe_agg}.#{scope.name}"
              lines << "    expect(results).to be_an(Array)"
              lines << "  end"
            end
            lines
          end

          def callable_scope_spec(scope, safe_agg, create_cmd, create_method)
            lines = []
            lines << "  it \"accepts arguments and returns an Array\" do"
            lines << "    #{safe_agg}.#{create_method}(#{example_args(create_cmd)})"
            lines << "    results = #{safe_agg}.#{scope.name}(\"example\")"
            lines << "    expect(results).to be_an(Array)"
            lines << "  end"
            lines
          end

          def find_scope_create_cmd(aggregate)
            aggregate.commands.find do |cmd|
              Hecks::Conventions::CommandContract.find_self_ref(cmd.attributes, aggregate.name).nil?
            end
          end

          def derive_scope_method(cmd, agg)
            Hecks::Conventions::CommandContract.method_name(cmd.name, agg.name).to_s
          end

          def create_args_override(cmd, field, value)
            parts = cmd.attributes.map do |attr|
              if attr.name.to_s == field
                "#{attr.name}: #{value}"
              else
                "#{attr.name}: #{example_value(attr)}"
              end
            end
            parts.join(", ")
          end
        end
      end
    end
  end
end

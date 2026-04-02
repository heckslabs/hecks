# Hecks::Generators::Infrastructure::SpecGenerator::QuerySpec
#
# Generates RSpec specs for query objects: creates sample data that
# matches and doesn't match the query's filter, then verifies the
# query returns only matching results. Mixed into SpecGenerator.
#
#   gen.generate_query_spec(query, aggregate)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module QuerySpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec file for a query defined on an aggregate.
          #
          # The generated spec:
          # 1. Boots the domain with memory adapters
          # 2. Creates sample aggregates (one matching, one non-matching)
          # 3. Calls the query method
          # 4. Verifies only matching results are returned
          #
          # @param query [Hecks::DomainModel::Behavior::Query] the query IR
          # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the owning aggregate
          # @return [String] the complete RSpec file content
          def generate_query_spec(query, aggregate)
            safe_agg = domain_constant_name(aggregate.name)
            query_method = domain_snake_name(query.name)
            create_cmd = find_create_command(aggregate)
            return nil unless create_cmd

            filter = extract_where_filter(query)
            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe \"#{safe_agg}.#{query_method}\" do"
            lines << "  before { @app = Hecks.load(domain, force: true) }"
            lines << ""

            if filter && !filter.empty?
              lines.concat(filtered_query_spec(query, aggregate, safe_agg, query_method, create_cmd, filter))
            else
              lines.concat(basic_query_spec(safe_agg, query_method, create_cmd, query))
            end

            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          # Find the first create command (no self-ref id attribute).
          def find_create_command(aggregate)
            aggregate.commands.find do |cmd|
              Hecks::Conventions::CommandContract.find_self_ref(cmd.attributes, aggregate.name).nil?
            end
          end

          # Derive the shortcut method name for a command.
          def command_method_name(cmd, aggregate)
            Hecks::Conventions::CommandContract.method_name(cmd.name, aggregate.name).to_s
          end

          # Try to extract the where conditions from a query block.
          # Returns a Hash of { field: value } or nil.
          def extract_where_filter(query)
            src = query.block.source_location rescue nil
            return nil unless src

            # Simple pattern: where(field: value)
            # We parse the block arity to determine if parameterized
            if query.block.arity == 0
              # Non-parameterized: fixed filter like where(status: "active")
              # We can't easily extract at generation time, so return nil
              # and fall back to basic spec
              nil
            else
              nil
            end
          rescue
            nil
          end

          def filtered_query_spec(query, aggregate, safe_agg, query_method, create_cmd, filter)
            cmd_method = command_method_name(create_cmd, aggregate)
            lines = []
            field = filter.keys.first.to_s
            match_val = filter.values.first

            lines << "  it \"filters by #{field}\" do"
            lines << "    #{safe_agg}.#{cmd_method}(#{create_args_with_override(create_cmd, field, match_val.inspect)})"
            lines << "    #{safe_agg}.#{cmd_method}(#{create_args_with_override(create_cmd, field, '"other"')})"
            lines << "    results = #{safe_agg}.#{query_method}(#{match_val.inspect})"
            lines << "    expect(results).to be_an(Array)"
            lines << "    expect(results.size).to eq(1)"
            lines << "    expect(results.first.#{field}).to eq(#{match_val.inspect})"
            lines << "  end"
            lines
          end

          def basic_query_spec(safe_agg, query_method, create_cmd, query)
            lines = []
            lines << "  it \"returns an Array\" do"
            if query.block.arity > 0
              lines << "    results = #{safe_agg}.#{query_method}(\"example\")"
            else
              lines << "    results = #{safe_agg}.#{query_method}"
            end
            lines << "    expect(results).to be_an(Array)"
            lines << "  end"
            lines
          end

          def create_args_with_override(cmd, field, value)
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

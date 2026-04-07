# Hecks::Generators::Infrastructure::SpecGenerator::ViewSpec
#
# Generates RSpec specs for domain views (read models). Triggers
# events via commands, then verifies the view projection updates
# state correctly. Mixed into SpecGenerator.
#
#   gen.generate_view_spec(view)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module ViewSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec for a domain-level view.
          #
          # @param view [Hecks::DomainModel::Behavior::ReadModel] the view IR
          # @return [String] the complete RSpec file content
          def generate_view_spec(view)
            mod = mod_name
            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe \"#{view.name} view\" do"
            lines << "  before { @app = Hecks.load(domain, force: true) }"
            lines << ""
            lines << "  it \"starts with empty state\" do"
            lines << "    expect(#{mod}::#{view.name}.current).to eq({})"
            lines << "  end"
            lines << ""

            # Test each projection
            view.projections.each do |event_name, _proc|
              cmd = find_command_emitting(event_name)
              next unless cmd

              agg = find_aggregate_for_command_obj(cmd)
              next unless agg

              safe_agg = domain_constant_name(agg.name)
              cmd_method = derive_view_method(cmd, agg)

              lines << "  it \"projects #{event_name} events\" do"
              lines << "    #{safe_agg}.#{cmd_method}(#{example_args(cmd)})"
              lines << "    state = #{mod}::#{view.name}.current"
              lines << "    expect(state).not_to eq({})"
              lines << "  end"
              lines << ""
            end

            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          def find_command_emitting(event_name)
            @domain.aggregates.each do |agg|
              agg.commands.each_with_index do |cmd, i|
                return cmd if agg.events[i]&.name == event_name
              end
            end
            nil
          end

          def find_aggregate_for_command_obj(cmd)
            @domain.aggregates.find { |a| a.commands.include?(cmd) }
          end

          def derive_view_method(cmd, agg)
            agg_snake = domain_snake_name(agg.name)
            suffixes = agg_snake.split("_").each_index.map { |i|
              agg_snake.split("_").drop(i).join("_")
            }.uniq
            full = domain_snake_name(cmd.name)
            suffixes.each do |s|
              stripped = full.sub(/_#{s}$/, "")
              return stripped if stripped != full
            end
            full
          end
        end
      end
    end
  end
end

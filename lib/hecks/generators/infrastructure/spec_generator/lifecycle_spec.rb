# Hecks::Generators::Infrastructure::SpecGenerator::LifecycleSpec
#
# Generates RSpec specs for aggregate lifecycles: verifies default state
# on creation, walks each transition command, and checks status predicates.
# Validates event log after each transition. Mixed into SpecGenerator.
#
#   gen.generate_lifecycle_spec(aggregate)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module LifecycleSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec for an aggregate's lifecycle.
          #
          # @param aggregate [Hecks::BluebookModel::Structure::Aggregate]
          # @return [String, nil] the RSpec file content, or nil if no lifecycle
          def generate_lifecycle_spec(aggregate)
            lc = aggregate.lifecycle
            return nil unless lc

            safe_agg = bluebook_constant_name(aggregate.name)
            create_cmd = find_create_cmd(aggregate)
            return nil unless create_cmd

            create_method = derive_method(create_cmd, aggregate)
            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe \"#{safe_agg} lifecycle\" do"
            lines << "  before { @app = Hecks.load(domain, force: true) }"
            lines << ""

            # Default state
            lines << "  it \"starts in '#{lc.default}' state\" do"
            lines << "    agg = #{safe_agg}.#{create_method}(#{example_args(create_cmd)})"
            lines << "    expect(agg.#{lc.field}).to eq(\"#{lc.default}\")"
            lines << "  end"
            lines << ""

            # Each transition
            lc.transitions.each do |cmd_name, target_spec|
              target = target_spec.is_a?(Hash) ? target_spec[:target] : target_spec
              cmd = aggregate.commands.find { |c| c.name == cmd_name }
              next unless cmd

              cmd_method = derive_method(cmd, aggregate)
              event_name = cmd.inferred_event_name

              lines << "  it \"#{cmd_name} transitions to '#{target}'\" do"
              lines << "    agg = #{safe_agg}.#{create_method}(#{example_args(create_cmd)})"

              # Walk through prior transitions if needed
              prior = transitions_before(lc, cmd_name)
              prior.each do |prior_cmd_name|
                prior_cmd = aggregate.commands.find { |c| c.name == prior_cmd_name }
                next unless prior_cmd
                prior_method = derive_method(prior_cmd, aggregate)
                lines << "    #{safe_agg}.#{prior_method}(#{update_args(prior_cmd, aggregate)})"
              end

              lines << "    #{safe_agg}.#{cmd_method}(#{update_args(cmd, aggregate)})"
              lines << "    updated = #{safe_agg}.find(agg.id)"
              lines << "    expect(updated.#{lc.field}).to eq(\"#{target}\")"
              lines << "    event_names = @app.events.map { |e| e.class.name.split(\"::\").last }"
              lines << "    expect(event_names).to include(\"#{event_name}\")"
              lines << "  end"
              lines << ""
            end

            # Predicate methods
            lines << "  it \"generates status predicates\" do"
            lines << "    agg = #{safe_agg}.#{create_method}(#{example_args(create_cmd)})"
            lines << "    expect(agg.#{lc.default}?).to be true"
            other_states = lc.states - [lc.default]
            other_states.first(2).each do |state|
              lines << "    expect(agg.#{state}?).to be false"
            end
            lines << "  end"

            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          def find_create_cmd(aggregate)
            aggregate.commands.find do |cmd|
              Hecks::Conventions::CommandContract.find_self_ref(cmd.attributes, aggregate.name).nil?
            end
          end

          def derive_method(cmd, agg)
            Hecks::Conventions::CommandContract.method_name(cmd.name, agg.name).to_s
          end

          def update_args(cmd, agg)
            self_ref = Hecks::Conventions::CommandContract.find_self_ref(cmd.attributes, agg.name)

            cmd.attributes.map { |attr|
              if self_ref && attr.name == self_ref.name
                "#{attr.name}: agg.id"
              else
                "#{attr.name}: #{example_value(attr)}"
              end
            }.join(", ")
          end

          # Returns the list of transition command names that must execute
          # before cmd_name, based on declaration order.
          def transitions_before(lc, cmd_name)
            ordered = lc.transitions.keys
            idx = ordered.index(cmd_name)
            return [] unless idx && idx > 0

            # Only include transitions that are needed to reach the
            # required from-state (if constrained)
            from = lc.from_for(cmd_name)
            return [] unless from

            prior = []
            ordered.each do |name|
              break if name == cmd_name
              prior << name
            end
            prior
          end
        end
      end
    end
  end
end

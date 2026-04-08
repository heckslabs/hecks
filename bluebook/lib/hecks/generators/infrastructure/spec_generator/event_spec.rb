module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        # Hecks::Generators::Infrastructure::SpecGenerator::EventSpec
        #
        # Generates RSpec specs for events: frozen state, timestamp,
        # and attribute carriage. Mixed into SpecGenerator.
        #
        module EventSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec file for an event class.
          #
          # The generated spec covers:
          # - Immutability: verifies the event is frozen after construction
          # - Timestamp: verifies +occurred_at+ returns a +Time+ instance
          # - Attribute carriage: verifies each attribute is accessible and returns
          #   the expected example value (or is non-nil for Date/DateTime types)
          #
          # @param event [Hecks::BluebookModel::Behavior::Event] the event IR
          # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the owning
          #   aggregate, used to build the fully qualified class name
          # @return [String] the complete RSpec file content
          def generate_event_spec(event, aggregate)
            safe_agg = bluebook_constant_name(aggregate.name)
            fqn = full_class_name("#{safe_agg}::Events::#{event.name}")
            lines = []

            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe #{fqn} do"
            lines << "  subject(:event) { described_class.new(#{example_args(event)}) }"
            lines << ""
            lines << "  it \"is frozen\" do"
            lines << "    expect(event).to be_frozen"
            lines << "  end"
            lines << ""
            lines << "  it \"records when it occurred\" do"
            lines << "    expect(event.occurred_at).to be_a(Time)"
            lines << "  end"

            event.attributes.each do |attr|
              lines << ""
              if %w[Date DateTime].include?(attr.type.to_s)
                lines << "  it \"carries #{attr.name}\" do"
                lines << "    expect(event.#{attr.name}).not_to be_nil"
                lines << "  end"
              else
                lines << "  it \"carries #{attr.name}\" do"
                lines << "    expect(event.#{attr.name}).to eq(#{example_value(attr)})"
                lines << "  end"
              end
            end

            lines << "end"
            lines.join("\n") + "\n"
          end
        end
      end
    end
  end
end

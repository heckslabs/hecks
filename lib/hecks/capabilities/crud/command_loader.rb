# Hecks::Capabilities::Crud::CommandLoader
#
# Generates and evaluates Ruby command and event classes for CRUD stubs.
# Extracted from the CRUD capability to keep each file under 200 lines.
#
#   Hecks::Capabilities::Crud::CommandLoader.load(agg, commands, events, mod_name)
#
module Hecks
  module Capabilities
    module Crud
      # Hecks::Capabilities::Crud::CommandLoader
      #
      # Generates and evaluates Ruby command and event classes for CRUD stubs.
      #
      module CommandLoader
        # Generate and eval Ruby command classes for the new stubs.
        #
        # @param agg [BluebookModel::Structure::Aggregate] the aggregate
        # @param commands [Array<BluebookModel::Behavior::Command>] new commands
        # @param events [Array<BluebookModel::Behavior::BluebookEvent>] corresponding events
        # @param mod_name [String] the domain module name
        # @return [void]
        def self.load(agg, commands, events, mod_name)
          commands.each_with_index do |cmd, i|
            event = events[i]
            event_source = Generators::Domain::EventGenerator.new(
              event, domain_module: mod_name, aggregate_name: agg.name
            ).generate
            RubyVM::InstructionSequence.compile(event_source, "crud_event_#{cmd.name}").eval

            source = if cmd.name.start_with?("Delete")
              delete_command_source(cmd, event, agg, mod_name)
            else
              Generators::Domain::CommandGenerator.new(
                cmd, domain_module: mod_name, aggregate_name: agg.name,
                aggregate: agg, event: event
              ).generate
            end
            RubyVM::InstructionSequence.compile(source, "crud_cmd_#{cmd.name}").eval
          end
        end

        # Generate source for a delete command that removes from the repository.
        #
        # @return [String] Ruby source code
        def self.delete_command_source(cmd, event, agg, mod_name)
          ref_name = cmd.references.first.name
          <<~RUBY
            module #{mod_name}
              class #{agg.name}
                module Commands
                  class #{cmd.name}
                    include Hecks::Command
                    emits "#{event.name}"
                    attr_reader :#{ref_name}
                    def initialize(#{ref_name}: nil)
                      @#{ref_name} = #{ref_name}
                    end
                    def call
                      _id = #{ref_name}.respond_to?(:id) ? #{ref_name}.id : #{ref_name}
                      existing = repository.find(_id)
                      raise #{mod_name}::Error, "#{agg.name} not found: \#{_id}" unless existing
                      repository.delete(_id)
                      existing
                    end
                    private
                    def persist_aggregate; end # already deleted in call
                  end
                end
              end
            end
          RUBY
        end
        private_class_method :delete_command_source
      end
    end
  end
end

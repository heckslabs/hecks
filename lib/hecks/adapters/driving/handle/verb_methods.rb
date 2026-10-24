require_relative "../../../naming"

module Hecks
  module Adapters
    module Driving
      class Handle
        # The two names each non-creating verb gets on a handle (ADR 0120): `name!` dispatches
        # and `name` answers the verb's IR command. Both are real singleton methods, not
        # method_missing, so a verb named `freeze` or `send` (Account::Freeze,
        # ExternalTransfer::Send) wins over the Kernel method instead of silently hitting it.
        module VerbMethods
          # Object methods a bare verb name never replaces: identity, introspection and
          # copying, which Ruby itself, `Hash` and test doubles call on any object.
          CORE_NAMES = %i[__send__ __id__ object_id class singleton_class hash equal? eql? == is_a?
                          kind_of? instance_of? respond_to? respond_to_missing? method_missing method
                          public_send instance_variable_get instance_variable_set instance_variables
                          define_singleton_method nil? dup clone itself tap then inspect to_s].freeze

          # The names a bare verb leaves alone: every method a handle defines, plus `CORE_NAMES`.
          #
          # @return [Array<Symbol>] the reserved method names
          def self.reserved_names
            @reserved_names ||= (Handle.instance_methods(false) + Handle.private_instance_methods(false) +
                                 private_instance_methods(false) + CORE_NAMES).uniq.freeze
          end

          private

          def define_verb_methods
            @ir.commands.reject(&:creates?).each do |command|
              name = Naming.snake(command.hecks_name)
              define_singleton_method("#{name}!") { |**args| run(command, **args) }
              define_singleton_method(name) { command } unless keeps_its_name?(name.to_sym)
            end
          end

          # A field reader, a method of the handle's own, or an Object method Ruby's machinery
          # calls keeps its name; the verb's bang form still dispatches.
          def keeps_its_name?(name)
            @state.key?(name) || reader?(name) || VerbMethods.reserved_names.include?(name)
          end
        end
      end
    end
  end
end

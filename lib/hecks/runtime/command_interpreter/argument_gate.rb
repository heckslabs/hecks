require_relative "../../naming"
require_relative "../errors"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class CommandInterpreter
      # The payload gate: a command takes the arguments it declares, all of them and no others.
      module ArgumentGate
        private

        # Refuses any argument the command does not declare.
        # Addressing keys (`id`, the aggregate's identity heads, the reference key)
        # and saga correlation keys are allowed through.
        #
        # `extra_identity_heads:` carries the identity heads of each entity hop an entity
        # dispatch walks; `[]` for a plain aggregate or port-operation dispatch.
        def refuse_unknown_arguments(domain, aggregate, command, args, extra_identity_heads: [])
          addressing = [:id, *aggregate.identity_heads, *extra_identity_heads, reference_key(command)] +
                       correlation_keys(domain)
          known      = (command.attributes.map(&:name) + addressing).compact.map(&:to_sym)
          # Sorted: refusal wording is pinned byte-for-byte, so it cannot follow payload order.
          unknown = (args.keys.map(&:to_sym) - known).sort
          return if unknown.empty?

          raise UnknownArgument,
                RefusalWording.render_site("UnknownArgument", "unknown_args",
                                           command: command.hecks_name, unknown: unknown,
                                           declared: declared_names(command))
        end

        # Refuses a declared, non-optional argument that is missing. Without it a missing
        # argument surfaces later as a misleading coercion error about a mistake the caller
        # did not make.
        #
        # `aggregate:` is set only for a port operation, whose identity attribute is
        # promoted into routing by `to:` and so never appears in `args`; it is exempted.
        def refuse_absent_arguments(command, args, aggregate: nil)
          given    = args.keys.map(&:to_sym)
          exempt   = aggregate && command.respond_to?(:identity_attribute) &&
                     command.identity_attribute(aggregate.hecks_name)&.name
          required = command.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym } - [exempt]
          # Sorted, for the same reason as the unknown list.
          absent = (required - given).sort
          return if absent.empty?

          raise AbsentArgument,
                RefusalWording.render_site("AbsentArgument", "absent_args",
                                           command: command.hecks_name, absent: absent,
                                           declared: declared_names(command))
        end

        # An empty list must still read as a sentence; only the empty case is worded differently.
        def declared_names(command) = command.attributes.map(&:name)

        # A saga threads its correlation key through every leg's payload, so the key arrives on
        # commands that never declare it. Refusing it would break every saga.
        def correlation_keys(domain)
          Array(@registry.bluebook(domain)&.process_managers)
            .filter_map { |saga| saga.correlates_by && saga.correlation_head }
        end

        def reference_key(command)
          target = command.references.to_s
          return nil if target.empty?

          Naming.reference_key(target)
        end
      end
    end
  end
end

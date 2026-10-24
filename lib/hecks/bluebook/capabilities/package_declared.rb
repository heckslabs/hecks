module Hecks
  module Bluebook
    module Capabilities
      # A capability the language defines no contract for belongs to the package that provides it.
      # Each of its `provides` keys names something the chapter declares, and the kind of that
      # target is read off what it names. Extended onto {Capabilities}, whose singleton methods
      # these become.
      module PackageDeclared
        # Every kind a package-declared key may name: a command or query ("Aggregate.Name"), a
        # port operation ("Aggregate.Port.Operation"), a lifecycle mark ("Aggregate.mark_name")
        # or an attribute ("Aggregate.attribute").
        KINDS = %i[command query port_operation mark attribute].freeze

        # Every kind `verb` names in `chapter`; more than one means the target is ambiguous.
        #
        # @param chapter [Bluebook::Chapter] the chapter that declares the aggregate
        # @param verb [String] the key's target, spelled as one of {KINDS}
        # @return [Array<Symbol>] the kinds it names, empty when it names nothing
        def kinds_of(chapter, verb)
          aggregate_name, member = verb.to_s.split(".", 2)
          aggregate = chapter.aggregate(aggregate_name)
          return [] unless aggregate && member
          # The port is declared in the hecksagon, which attaches after the chapter is built, so
          # only the spelling is checkable here; `Registry#verify!` checks the operation.
          return member.count(".") == 1 ? [:port_operation] : [] if member.include?(".")

          member_kinds(aggregate, member)
        end

        # The value a package-declared key exports: the qualified verb of a command, query or port
        # operation, the states of a lifecycle mark, or an attribute's name and `default:`.
        #
        # @param chapter [Bluebook::Chapter] the chapter that declares the aggregate
        # @param verb [String] the key's target
        # @return [String, Array<String>, Hash{Symbol => Object}] what the reader is handed
        # @raise [ArgumentError] when `verb` names nothing, or more than one kind, in `chapter`
        def resolved_value(chapter, verb)
          kinds = kinds_of(chapter, verb)
          raise ArgumentError, "#{chapter.name} declares no single target named #{verb.inspect}" unless kinds.one?

          aggregate_name, member = verb.split(".", 2)
          case kinds.first
          when :mark then chapter.aggregate(aggregate_name).lifecycle.marked(member)
          when :attribute then { attribute: member, default: filled_value(attribute_default(chapter, verb)) }
          else "#{chapter.name}::#{verb}"
          end
        end

        private

        def member_kinds(aggregate, member)
          member_names(aggregate).select { |_, names| names.include?(member) }.keys
        end

        # Every name an aggregate declares, by the kind of thing it names.
        def member_names(aggregate)
          { command:   aggregate.commands.map(&:hecks_name),
            query:     aggregate.queries.map { |query| query.name.to_s },
            mark:      aggregate.lifecycle&.marks&.keys.to_a.map(&:to_s),
            attribute: aggregate.attributes.map { |attribute| attribute.name.to_s } }
        end
      end
    end
  end
end

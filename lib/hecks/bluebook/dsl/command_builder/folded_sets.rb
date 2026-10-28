module Hecks
  module Bluebook
    module DSL
      class CommandBuilder
        # `attribute :name, Type, sets: true`: the argument and the plain `sets :name` that a following
        # line would record, at the same position among the command's mutations.
        module FoldedSets
          # Declares one argument and, with `sets: true`, the plain `sets` of the owner's field of the
          # same name.
          #
          # @param name [Symbol] the argument's name
          # @param type [Array] the type, as `attribute` takes it
          # @param sets [Boolean] true to also record `sets name`
          # @param options [Hash] the keywords `attribute` takes
          # @return [void]
          # @raise [Bluebook::DSL::Malformed] if `sets:` is anything but true
          def attribute_impl(name, *type, sets: false, **)
            super(name, *type, **)
            return if sets == false

            refuse_unreadable_sets_flag!(name, sets)
            (@folded_sets ||= []) << name.to_sym
            sets_impl(name)
          end

          private

          def refuse_unreadable_sets_flag!(name, flag)
            return if flag == true

            raise Malformed, "#{@name}'s attribute :#{name} takes sets: true or no sets: at all, not #{flag.inspect}"
          end

          # Refuses an attribute that says `sets: true` where the owner has no field of that name.
          def refuse_unowned_folded_sets!
            missing = (@folded_sets || []).reject { |name| @owner_attributes.any? { |attr| attr.name == name } }
            return if missing.empty?

            raise Malformed,
                  "#{@name}'s attribute#{"s" if missing.size > 1} #{missing.map { |name| ":#{name}" }.join(", ")} " \
                  "say sets: true, but the owner declares no field of that name to set — " \
                  "declare it on the owner, or drop sets: true"
          end
        end
      end
    end
  end
end

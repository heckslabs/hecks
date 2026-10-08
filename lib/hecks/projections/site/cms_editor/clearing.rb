# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # A command argument that only clears: the bluebook's way of setting an optional field back
        # to nothing is an optional argument the command never reads, named as the source of a
        # `sets <field>, to: :<argument>` mutation (`attribute :nothing, Body, optional: true`,
        # `sets :draft_body, to: :nothing`). Nobody types into it, so the editor offers no field
        # for it and the server sends its empty value itself: an empty list, or nothing at all.
        #
        # The shape decides it, never a name. The argument is optional, is no attribute of the
        # aggregate, feeds only plain `sets` mutations of other fields that can be empty (optional
        # or a list), and no `given` or `ensures` of the command reads it.
        module Clearing
          module_function

          # @param command [Bluebook::Command] the command
          # @param aggregate [Bluebook::Aggregate] the aggregate it belongs to
          # @return [Array<Bluebook::Attribute>] the command's arguments that only clear
          def of(command, aggregate)
            command.attributes.select { |argument| only_clears?(argument, command, aggregate) }
          end

          # @param shaped [Hash{String => Object}] the command as the editor reads it
          # @param only [Array<Bluebook::Attribute>] its arguments that only clear
          # @return [Hash{String => Object}] `shaped` without those arguments, and naming the ones
          #   that are lists as `empty`, for the editor to send as empty lists
          def apply(shaped, only)
            return shaped if only.empty?

            names = only.map { |argument| argument.name.to_s }
            lists = only.select(&:list?).map { |argument| argument.name.to_s }
            kept = shaped["attributes"].reject { |attr| names.include?(attr["name"]) }
            shaped.merge("attributes" => kept, **(lists.empty? ? {} : { "empty" => lists }))
          end

          # @return [Boolean] whether `argument` is a clearing argument of `command`
          def only_clears?(argument, command, aggregate)
            return false if !argument.optional? || named?(aggregate.attributes, argument.name)

            fed = fed_by(argument, command)
            !fed.empty? && fed.all? { |mutation| clears?(mutation, aggregate) } && !read?(argument, command)
          end

          # @return [Array<Bluebook::Mutation>] the mutations that take their value from `argument`
          def fed_by(argument, command)
            command.mutations.select { |mutation| mutation.source.is_a?(Symbol) && named?([argument], mutation.source) }
          end

          # @return [Boolean] whether any of `attributes` is called `name`
          def named?(attributes, name) = attributes.any? { |held| held.name.to_s == name.to_s }

          # @return [Boolean] whether the mutation is a plain set of a field that can be empty
          def clears?(mutation, aggregate)
            target = aggregate.attributes.find { |held| held.name.to_s == mutation.target.to_s }
            mutation.op == :set && !target.nil? && (target.optional? || target.list?)
          end

          # @return [Boolean] whether a `given` or `ensures` of the command names the argument
          def read?(argument, command)
            word = /\b#{Regexp.escape(argument.name.to_s)}\b/
            [*command.givens, *command.ensures].any? { |rule| word.match?(rule.canonical.to_s) }
          end
        end
      end
    end
  end
end

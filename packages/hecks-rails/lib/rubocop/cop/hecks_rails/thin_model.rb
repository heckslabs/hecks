require "rubocop"

module RuboCop
  module Cop
    module HecksRails
      # Flags a validation, a callback or an association inside a `Hecks::Rails::Model`.
      #
      # A thin model stands for an aggregate whose rules the bluebook already holds. A `validates`
      # line, a `before_save` or a `has_many` beside it is a second author for one of those rules,
      # and the two drift. An app loads it with `require: hecks/rails/rubocop`.
      #
      # @example
      #   class Account < Hecks::Rails::Model
      #     validates :number, presence: true          # bad
      #     belongs_to :customer                        # bad
      #     def label = "#{number} (#{status})"         # good
      #   end
      class ThinModel < Base
        MSG = "A Hecks::Rails::Model holds no `%<name>s`: the bluebook owns the aggregate's rules and " \
              "references, so declare it there; keep presentation methods here.".freeze

        # Association macros: a reference is read explicitly, never loaded behind a call.
        ASSOCIATIONS = %i[has_many has_one belongs_to has_and_belongs_to_many].freeze

        # Validation macros besides the `validates_*_of` family, which `macro?` matches by shape.
        VALIDATIONS = %i[validates validates! validate validates_with].freeze

        # @!method hecks_model?(node)
        def_node_matcher :hecks_model?, <<~PATTERN
          (class _ (const (const {nil? (const {nil? cbase} :Hecks)} :Rails) :Model) _)
        PATTERN

        # Flags each forbidden macro called in the body of a `Hecks::Rails::Model` subclass.
        #
        # @param node [RuboCop::AST::ClassNode] the class being visited
        # @return [void]
        def on_class(node)
          return unless hecks_model?(node)

          node.body&.each_node(:send) do |send|
            next unless send.receiver.nil? && macro?(send.method_name)

            add_offense(send, message: format(MSG, name: send.method_name))
          end
        end

        private

        def macro?(name)
          ASSOCIATIONS.include?(name) || VALIDATIONS.include?(name) || name.match?(/\A(before|after|around)_/) ||
            name.match?(/\Avalidates_\w+_of\z/)
        end
      end
    end
  end
end

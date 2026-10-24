module RuboCop
  module Cop
    module Hecks
      # Flags a validation, callback or association declared in a `Hecks::Rails::Model`.
      #
      # Every rule of a Hecks domain is declared in its bluebook. A `validates` or `before_save`
      # in the Rails model would be a second author for a rule the domain already states, and the
      # two drift; an association would load records the domain keeps as plain identity values.
      #
      # @example
      #   class Account < Hecks::Rails::Model
      #     aggregate "Ledger.Account"
      #     validates :owner, presence: true  # bad
      #     has_many :entries                 # bad
      #   end
      class RailsModelRules < Base
        MSG = "`%<call>s` declares a rule or an association in a Hecks::Rails::Model. State the rule in the " \
              "bluebook instead; the model is a skin over the aggregate.".freeze

        FORBIDDEN = /\A(validates?(_\w+)?|(before|after|around)_\w+|has_(many|one|and_belongs_to_many)|belongs_to)\z/

        # @!method model_parent?(node)
        def_node_matcher :model_parent?, <<~PATTERN
          (class _ (const (const (const {nil? cbase} :Hecks) :Rails) :Model) ...)
        PATTERN

        # Flags a forbidden declaration written directly in a model's body.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          return unless node.receiver.nil? && FORBIDDEN.match?(node.method_name.to_s)
          return unless inside_model?(node)

          add_offense(node, message: format(MSG, call: node.method_name))
        end

        private

        def inside_model?(node)
          node.each_ancestor(:class).any? { |klass| model_parent?(klass) }
        end
      end
    end
  end
end

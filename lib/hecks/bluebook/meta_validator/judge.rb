require_relative "judge/identity"
require_relative "judge/dispatching"
require_relative "judge/walking"
require_relative "judge/cells"

module Hecks
  module Bluebook
    module MetaValidator
      # Offers every declaration in a built bluebook to the meta-domain by
      # walking the plan itself, so no verb the language declares can go
      # un-offered by omission.
      class Judge
        include Readings
        include Identity
        include Dispatching
        include Walking
        include Cells

        # ValueObject before Entity: an entity's own attributes may
        # reference a value object, which must exist before it resolves.
        EAGER_CHILDREN = { "Aggregate" => %w[ValueObject Entity] }.freeze

        # Command and Query are reused for a piece's own commands/queries,
        # since the plan derives a category's parent from its creating
        # command's one `*_id` argument and cannot express a second parent.
        WITHIN_ENTITY = %w[Command Query].freeze

        # Where a node sits among siblings is a fact about the walk, not
        # the node, so the walk supplies it rather than reading a stored
        # field; Reconstruction depends on this being the source order.
        POSITION = "position".freeze

        # `owner_id` is a second reserved head (beside `position`): it
        # names whichever record is walking this one right now, aggregate
        # or entity, so Command/Query address the right piece. It is
        # never a declared attribute, so it can't be read through
        # `field_value`.
        OWNER = "owner_id".freeze

        # Where the walk stands: the node being offered, its category, the id of the record that
        # holds it and its position among its siblings.
        Visit = Struct.new(:category, :node, :parent_id, :index)

        # One element of an appended list: the list it joins, the row, its position, the id of the
        # record appended onto and the aggregate its value-object types resolve against.
        Appending = Struct.new(:list_name, :append, :row, :index, :id, :owner_id)

        attr_reader :refusals

        # The runtime dispatched into, not just the refusals, so a caller
        # can read the resulting records back out.
        attr_reader :runtime

        def initialize(bluebook)
          @bluebook = bluebook
          @refusals = []
          @runtime  = MetaValidator.fresh_runtime
          @plan     = Plan.for(MetaValidator.grammar_registry)
          judge!
        end

        private

        def judge!
          visit = Visit.new("Bluebook", @bluebook, nil, 0)
          declare_node(visit)
          detail_node(visit)
        end
      end
    end
  end
end

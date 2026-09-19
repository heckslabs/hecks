module Hecks
  module Bluebook
    # An attribute that points at another aggregate's head.
    #
    # Holds the target directly, and answers `resolve` with the target's
    # Aggregate, rather than being spelled as the string `"Reference<Customer>"`
    # that `AggregateBuilder#reference_to` and `CommandBuilder#cross_reference`
    # would otherwise mint from the real constant just handed in. That string
    # would need five separate readers to parse back apart — a regex in the
    # command interpreter, string equality in the read-model interpreter and
    # the SQLite adapter, and `delete_prefix` in the bluebook builder — one
    # writer inventing a spelling, five readers reparsing it.
    #
    # Resolution is lazy and deliberately so: `reference_to
    # Customer` may name an aggregate declared lower in the file — banking's
    # Account points at Customer and survives only because Customer happens to
    # be written above — so the edge cannot be resolved at declaration time.
    # It resolves through the chapter's own IR (`Bluebook#aggregate`),
    # which is scoped by construction : the lookup cannot walk anywhere but
    # this chapter's declared heads, so a same-named aggregate in another
    # loaded domain is unreachable rather than defended against.
    #
    # `to_s` still spells `"Reference<Customer>"`, because `Attribute#to_h` is
    # part of the pinned byte-for-byte export contract. IR objects in
    # the graph, strings in the export.
    class Reference
      attr_reader :target_name

      # The Aggregate whose declaration carries this reference — the way
      # up to the chapter, stamped once every sibling has been read.
      attr_accessor :declared_in

      # @param target_name [Module, String, Symbol] the aggregate constant this
      #   reference points at, or its already-spelled name
      def initialize(target_name)
        @target_name = Naming.demodulise(target_name).to_s
      end

      # The Aggregate this points at, or nil when the target belongs to
      # another domain — a cross-domain target may legitimately not be loaded,
      # the same reading `across` policies get.
      #
      # @return [Bluebook::Aggregate, nil] the target aggregate, or `nil` when
      #   `declared_in`'s own chapter does not declare one by this name
      # @raise [DSL::Malformed] if `declared_in` is unset, so there is no
      #   chapter to resolve the target against
      def resolve
        unless declared_in
          raise DSL::Malformed,
                "#{self} cannot say which aggregate declares it, so it cannot " \
                "resolve — a reference that resolves to nothing is checked " \
                "against nothing"
        end

        declared_in.hecks_owner&.aggregate(@target_name)
      end

      # The IR spelling, the one the export carries.
      #
      # @return [String] `"Reference<TargetName>"`
      def to_s = "Reference<#{@target_name}>"
      def inspect = "#<Reference #{@target_name}>"

      # Value equality, not identity — without this, two references to
      # the same target, parsed from two separate bluebook reads (era
      # N's own boot and a held era's own shadow reconstruction,
      # coverage_check.rb's own comparison), are different objects and
      # compare unequal by Ruby's default `==`. `EraGuard::ShapeDiff
      # #diff_type`'s `held_type != current_type` check then reads as
      # true for every reference_to attribute on every mint, regardless
      # of whether the reference actually changed — a real refusal for
      # attributes nothing about. `declared_in` (which aggregate carries
      # this reference) is deliberately excluded: the same reference
      # attribute exists once, but its `held_type`/`current_type` come
      # from separately-parsed bluebooks with structurally different
      # (if same-shaped) owning aggregates, and `declared_in` is a
      # cross-reference for `resolve`, not part of what this attribute
      # itself is.
      #
      # @param other [Object] the value to compare against
      # @return [Boolean] whether `other` is a `Reference` to the same target
      def ==(other) = other.is_a?(Reference) && target_name == other.target_name
      alias eql? ==
      def hash = [self.class, target_name].hash
    end
  end
end

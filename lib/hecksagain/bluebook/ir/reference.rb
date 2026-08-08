module Hecksagain
  module Bluebook
    module IR
      # An attribute that points at another aggregate's head.
      #
      # This used to be the STRING `"Reference<Customer>"`, minted by
      # `AggregateBuilder#reference_to` and `CommandBuilder#cross_reference` from
      # a real constant that had just been handed in, and then parsed back apart
      # by a regex in the command interpreter, by string equality in the read-model
      # interpreter and the SQLite adapter, and by `delete_prefix` in the bluebook
      # builder. Five readers of a spelling one writer invented.
      #
      # It holds the TARGET instead, and answers `resolve` with the target's
      # IR::Aggregate. Resolution is LAZY and deliberately so: `reference_to
      # Customer` may name an aggregate declared lower in the file — banking's
      # Account points at Customer and survives only because Customer happens to
      # be written above — so the edge cannot be resolved at declaration time.
      # It resolves through the chapter's own IR (`IR::Bluebook#aggregate`),
      # which is scoped by construction : the lookup cannot walk anywhere but
      # this chapter's declared heads, so a same-named aggregate in another
      # loaded domain is unreachable rather than defended against.
      #
      # `to_s` still spells `"Reference<Customer>"`, because `Attribute#to_h` is
      # part of the pinned byte-for-byte export contract. IR objects in
      # the graph, strings in the export.
      class Reference
        attr_reader :target_name

        # The IR::Aggregate whose declaration carries this reference — the way
        # up to the chapter, stamped once every sibling has been read.
        attr_accessor :declared_in

        def initialize(target_name)
          @target_name = Naming.demodulise(target_name).to_s
        end

        # The IR::Aggregate this points at, or nil when the target belongs to
        # ANOTHER domain — a cross-domain target may legitimately not be loaded,
        # the same reading `across` policies get.
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
        def to_s = "Reference<#{@target_name}>"
        def inspect = "#<Reference #{@target_name}>"

        # VALUE EQUALITY, not identity — without this, two references to
        # the SAME target, parsed from two SEPARATE bluebook reads (era
        # N's own boot and a held era's own shadow reconstruction,
        # coverage_check.rb's own comparison), are different objects and
        # compare unequal by Ruby's default `==`. `EraGuard::ShapeDiff
        # #diff_type`'s `held_type != current_type` check then reads as
        # true for EVERY reference_to attribute on EVERY mint, regardless
        # of whether the reference actually changed — a real refusal for
        # attributes nothing about. `declared_in` (which aggregate carries
        # this reference) is deliberately excluded: the same reference
        # attribute exists once, but its `held_type`/`current_type` come
        # from separately-parsed bluebooks with structurally different
        # (if same-shaped) owning aggregates, and `declared_in` is a
        # cross-reference for `resolve`, not part of what this attribute
        # itself IS.
        def ==(other) = other.is_a?(Reference) && target_name == other.target_name
        alias eql? ==
        def hash = [self.class, target_name].hash
      end
    end
  end
end

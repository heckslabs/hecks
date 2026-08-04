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

      end
    end
  end
end

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
      # It holds the TARGET instead, and answers `resolve` with the aggregate
      # class. Resolution is LAZY and deliberately so: `reference_to Customer` may
      # name an aggregate declared lower in the file — banking's Account points at
      # Customer and survives only because Customer happens to be written above —
      # so the edge cannot be a class at declaration time. It resolves through the
      # chapter's namespace, which means Ruby's constant tree does the work and
      # there is no table to keep.
      #
      # `to_s` still spells `"Reference<Customer>"`, because `Attribute#to_h` is
      # part of the byte-for-byte contract with the Rust parser. Classes in the
      # graph, strings in the export.
      class Reference
        attr_reader :target_name

        # The aggregate class whose declaration carries this reference — the way
        # up to the chapter, stamped by `AggregateBuilder#build` once every
        # sibling has been read.
        attr_accessor :declared_in

        def initialize(target_name)
          @target_name = Naming.demodulise(target_name).to_s
        end

        # The aggregate class this points at, or nil when the target belongs to
        # ANOTHER domain — a cross-domain target may legitimately not be loaded,
        # the same reading `across` policies get.
        #
        # `false` on both constant calls is load-bearing: without it the lookup
        # walks up to Object, where a chapter loaded earlier in the process has
        # installed its own aggregates as top-level constants, and a reference
        # would silently resolve to another domain's class.
        def resolve
          unless declared_in
            raise DSL::Malformed,
                  "#{self} cannot say which aggregate declares it, so it cannot " \
                  "resolve — a reference that resolves to nothing is checked " \
                  "against nothing"
          end

          chapter = declared_in.hecks_owner
          return nil unless chapter&.const_defined?(@target_name, false)

          chapter.const_get(@target_name, false)
        end

        # The IR spelling, which the export and the Rust parser share.
        def to_s = "Reference<#{@target_name}>"
        def inspect = "#<Reference #{@target_name}>"

        # Compares equal to the string it replaces, so a consumer still holding
        # the old spelling reads correctly while it is migrated.
        def ==(other) = other.to_s == to_s
        alias eql? ==
        def hash = to_s.hash
      end
    end
  end
end

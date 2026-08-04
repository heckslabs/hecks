module Hecksagain
  module Bluebook
    module IR
      class Attribute
        attr_reader :name, :type, :default, :pattern, :admits

        # A Reference is kept AS ITSELF. Every other type is still a name, and
        # crosses over as its construct does.
        #
        # `admits` names an ALREADY-DECLARED closed set the value must belong
        # to — `Vocabulary::QueryComparator` — spelled aggregate-qualified
        # because the set is a value object INSIDE an aggregate, and the
        # aggregate is the only thing `reference_to` can reach.
        #
        # ON THE WIRE, because it is a RULE and not only a typing hint.
        #
        # It began as neither. The link existed so a generator could type
        # `WhereClause.op` as `WhereOp` — a typing convenience, not worth
        # moving 710 attribute records across eight goldens for. Then `admits`
        # grew teeth (coercion refuses a non-member) and the argument
        # inverted: a rule the wire does not carry is one a reader of the IR
        # cannot enforce, and a bluebook whose meaning depends on the reader
        # means two things. Proved rather than assumed — the same domain
        # refused "burnt" through one reading and emitted the event through
        # another.
        #
        # The wire carries the NAME, not the members. A reader resolves it
        # against the IR it holds, so the members are declared once and
        # copied nowhere — which is the same reason `admits` exists at all.
        def initialize(name:, type:, list: false, default: nil, optional: false, pattern: nil,
                       admits: nil)
          @name     = name.to_sym
          @type     = type.is_a?(Reference) ? type : type.to_s
          @list     = list
          @default  = default
          @optional = optional
          @pattern  = pattern
          @admits   = admits&.to_s
        end

        def list?   = @list
        def scalar? = !@list
        def reference? = @type.is_a?(Reference)

        # MAY THIS FACT BE LEFT OUT?
        #
        # Required is the default and by far the common case — a command takes
        # the arguments it declares, and all of them — so the EXCEPTION is what
        # gets marked. Marking the other way would annotate almost every
        # attribute in the corpus to say nothing.
        #
        # Only a COMMAND enforces this. An aggregate's own attributes are filled
        # by the commands that set them, and a value object's by its
        # constructor ; neither is a payload anyone hands in.
        def optional? = @optional

        # Held because a declared vocabulary pins it — spec/vocabulary_conformance
        # holds `Primitive`'s members to this list. The `primitive?` predicate that
        # used to read it had no caller anywhere and is gone.
        PRIMITIVES = %w[String Integer Float TrueClass FalseClass].freeze

        # `type` is spelled, never handed over. A Reference renders as
        # "Reference<Customer>" here because that is the export's pinned spelling.
        def to_h
          { name: @name, type: @type.to_s, list: @list, default: @default, optional: @optional,
            pattern: @pattern, admits: @admits }
        end
      end
    end
  end
end

require_relative "behaviour/attribute"
require_relative "../ir"
require_relative "../vocabulary"
require_relative "../naming"

module Hecks
  module Bluebook
    # One declared field on a construct — name, type (a primitive, a
    # Reference, or another construct's name, always spelled via `#spell`),
    # whether it's a list, its default/optional/pattern, and the closed set
    # it `admits`. What `attribute :x, Type` (or `identified_by`,
    # `reference_to`, etc.) actually mints, on an Aggregate, Entity, Command,
    # ValueObject, Query or PortOperation alike.
    class Attribute
      include Hecks::IR
      include Behaviour::Attribute

      emits_ir(
        name:         :name,
        type:         -> { @type.to_s },
        list:         :list?,
        default:      :default,
        optional:     :optional?,
        pattern:      :pattern,
        admits:       :admits,
        relationship: :relationship
      )

      attr_reader :name, :type, :default, :pattern, :admits, :relationship

      # A Reference is kept as itself. Every other type is still a name, and
      # crosses over as its construct does.
      #
      # `admits` names an already-declared closed set the value must belong
      # to — `Vocabulary::QueryComparator` — spelled aggregate-qualified
      # because the set is a value object inside an aggregate, and the
      # aggregate is the only thing `reference_to` can reach.
      #
      # On the wire, because it is a rule and not only a typing hint.
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
      # The wire carries the name, not the members. A reader resolves it
      # against the IR it holds, so the members are declared once and
      # copied nowhere — which is the same reason `admits` exists at all.
      #
      # @param name [Symbol, String] the attribute's name
      # @param type [Module, Bluebook::Reference, String, Symbol] the bare constant naming
      #   a primitive or a value object, a `reference_to`-built Reference, or already-spelled
      #   text
      # @param list [Boolean] whether this attribute holds a list of values rather than one
      # @param default [Object, nil] the value a new record starts with when none is given
      # @param optional [Boolean] whether a command may omit this attribute
      # @param pattern [String, nil] a regex source the value must match; shared-engine
      #   subset only (`PatternSubset`)
      # @param admits [String, nil] an already-declared closed set's aggregate-qualified
      #   name, such as `"Vocabulary::QueryComparator"`, that the value must belong to
      # @param relationship [Symbol, nil] the DSL word that minted this attribute
      #   (`:reference_to`, `:has_many`, `:has_one` or `:belongs_to`), or `nil` for an
      #   ordinary attribute
      def initialize(name:, type:, list: false, default: nil, optional: false, pattern: nil,
                     admits: nil, relationship: nil)
        @name     = name.to_sym
        @type     = spell(type)
        @list     = list
        @default  = default
        @optional = optional
        @pattern  = pattern
        @admits   = admits&.to_s
        @relationship = relationship&.to_s
      end

      # A bare constant in a bluebook is a name, even when Ruby has heard of it.
      #
      # `BluebookBuilder.build` says exactly this and installs a `const_missing`
      # resolver that hands back the symbol — `attribute :target, Target` becomes
      # the name "Target" and nothing looks Target up. That works only while the
      # lookup fails, and `Facade::Surface` installs every aggregate name as a
      # top-level constant (its own comment, and `ConstShim`'s, both say so).
      #
      # So in one process: boot a domain with an aggregate named `Target`, then
      # load a chapter whose own value object is called `Target`, and Ruby
      # resolves the constant before the hook is ever asked. The chapter is then
      # built against somebody else's aggregate — silently, with no refusal —
      # and the attribute stops meaning what the file plainly says.
      #
      # Demodulised, so both paths spell it the same: `:Target` and
      # `QualityControl::Target` are both "Target". A plain class stays itself —
      # `String` demodulises to "String" — so the ordinary case is untouched.
      # This does not undo the constant leak; it makes the leak unable to change
      # what a chapter means, which is the part that has to hold.
      def spell(type)
        return type if type.is_a?(Reference)
        return Naming.demodulise(type) if type.is_a?(Module)

        type.to_s
      end
      private :spell

      # Held because a declared vocabulary pins it — spec/vocabulary_conformance
      # holds `Primitive`'s members to this list.
      PRIMITIVES = Hecks::Vocabulary.fetch("Primitive")

      # `type` is spelled, never handed over. A Reference renders as
      # "Reference<Customer>" here because that is the export's pinned spelling.
    end
  end
end

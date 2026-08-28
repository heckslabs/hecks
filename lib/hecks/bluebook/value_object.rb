require_relative "behaviour/value_object"
require_relative "expression/ast_json"

module Hecks
  module Bluebook
    Invariant = Struct.new(:description, :canonical, :predicate, keyword_init: true)

    # A value object — a DECLARATION HOLDER, never instantiated.
    #
    # `ValueObjectBuilder` returns an anonymous subclass whose singleton
    # carries the declaration : attributes, invariants, members. Nothing ever
    # calls `.new` on one — coercion builds `Runtime::Value` wrappers, and
    # invariants run as canonical text through the Evaluator. The runtime
    # reaches a shape through `aggregate.value_object(name)`, the IR's own
    # finder ; there is no constant nesting and no second index.
    #
    # `to_h` does not move. It is a byte-for-byte contract pinned by the
    # golden fixtures, so it keeps spelling the short declared name, which
    # is what `hecks_name` carries. DECLARATIONS IN THE GRAPH, STRINGS IN THE
    # EXPORT.
    class ValueObject
      extend Construct
      # EXTENDED, not included — this construct is a class, so its
      # emission is a class method. See Hecks::IR's own note on
      # the two shapes.
      extend Hecks::IR
      extend Behaviour::ValueObject

      emits_ir(
        name:       :hecks_name,
        attributes: many(:attributes),
        # `ast:` — a JSON-serializable rendering of the SAME predicate
        # `canonical` already spells as text, alongside it rather than
        # replacing it (`canonical` stays the human-facing/doctest-facing
        # form; parsing it back would just re-derive what `ast` already
        # states directly). Ground truth and the full reasoning:
        # `Expression::AstJson`'s own header — built for `rust/host`'s
        # own mint-time invariant check (`reference_validate.rs`), which
        # has no kernel crate to parse `canonical` with.
        invariants: -> { invariants.map { |rule| { description: rule.description, canonical: rule.canonical, ast: Expression::AstJson.emit_predicate(rule.canonical) } } },
        closed_set: :closed_set?,
        # THE FIELD NAME IS STRINGIFIED, NEVER THE VALUE. A `member` row can
        # hold any of the scalar types an attribute declares — `Integer 84`
        # (`StatementFrequency#retention_months`, statements.bluebook), not
        # only `String` — and `value.to_s` used to erase that on the way
        # out, so `84` and `"84"` (a member some other row might
        # legitimately spell as text) became indistinguishable once they
        # reached `to_h`. The declared name still moves (`field.to_s`) —
        # that half was never a Ruby object with a type to lose.
        members:    -> { members.map { |member| member.map { |field, value| [field.to_s, value] } } }
      )

      class << self
        attr_reader :attributes, :invariants, :members

        # One declared shape — a subclass rather than an instance, so the thing
        # the bluebook declares and the thing Ruby holds are one object.
        def declare(name:, attributes: [], invariants: [], members: [], closed_set: !members.empty?)
          shape = Class.new(self)
          shape.hecks_name = name.to_s
          shape.absorb(attributes: attributes, invariants: invariants,
                       members: members, closed_set: closed_set)
          shape
        end

        def absorb(attributes:, invariants:, members:, closed_set:)
          @attributes = attributes
          @invariants = invariants
          @members    = members
          @closed_set = closed_set
        end
      end
    end
  end
end

require_relative "../../literal"
require_relative "../../vocabulary"

module Hecks
  # Reopened (see query_specification.rb for the namespace's own
  # summary) to add Common::COMPARATORS — the vendored comparator
  # vocabulary — and .render_value, the wire-rendering entry point
  # shared by every literal-bearing spec struct.
  module QuerySpecification
    # The vocabulary every query-shaped construct shares — the clause structs
    # (`WhereClause`, `OrderBy`, `LimitSpec`...), the `DSL` mixin that parses
    # them, and the comparison and null rules every engine answers by. It is
    # its own namespace so a plain `Bluebook::Query` and a
    # `ReadModel::Specification` say one thing the same way rather than each
    # carrying a copy.
    module Common
      # `none_in_state`, vendored addition not (yet) upstream hecks
      # (migration plan task 4): a cross-aggregate anti-join comparator --
      # `where ref: { none_in_state: "Claim:held" }` holds true when no
      # record in the named aggregate, keyed by this record's own field
      # value, is currently in the named state. plan.bluebook's own
      # description: "a keyed point lookup (HashMap hit), never a scan" --
      # a real, deliberate, pre-existing feature (WhereOp::NoneInState in
      # the old Rust runtime), not invented here -- see Runtime::
      # QueryInterpreter#holds?'s own comment for the evaluation side.
      COMPARATORS = Hecks::Vocabulary.symbols("QueryComparator")
    end

    # Renders a literal captured in a query clause as its self-describing
    # wire spelling, for a spec struct's `to_h`.
    #
    # The specification structs' own name for the one wire spelling — see
    # `Hecks::Literal`, which every other `to_h`-bound literal field
    # shares. Kept as a word here because the structs below read better
    # saying what they are doing than naming the module that does it.
    #
    # @param value [nil, Symbol, String, StateRef, Boolean, Integer, Float, Hash, Array] the
    #   literal as the bluebook author wrote it; Hash values and Array elements are
    #   rendered recursively
    # @return [String] the wire text: a Symbol keeps its colon, a String its double quotes,
    #   and a number, a boolean and `nil` are bare
    # @raise [ArgumentError] if `value`, or a value nested in it, is of any other class
    def self.render_value(value) = Literal.render(value)
  end
end

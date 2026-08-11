require "json"
require_relative "../../rendering"

module Hecksagain
  module Bluebook
    module Expression
      class EvaluationError < StandardError; end

      module Resolver
        SIGN_TESTS = %w[positive? negative? zero?].freeze

        # Which Comparison operator each sign test is sugar for, against the
        # literal 0 — declared the same way in Vocabulary::SignTest's
        # compares_via (language/bluebook/vocabulary.bluebook) ; spec/vocabulary_conformance_spec
        # holds the two tables equal.
        SIGN_TEST_OPERATORS = {
          "positive?" => ">",
          "negative?" => "<",
          "zero?"     => "=="
        }.freeze

        # The leaf grammar an expression's dotted/arithmetic side parses into.
        # Which node a string produces is a pure function of the string, so
        # parse() runs once per distinct leaf (folded into Evaluator's own
        # ast_cache — see evaluator.rb) and interpret() reads state/attrs
        # fresh on every call. Only Lookup — the true leaf — ever touches
        # state/attrs.
        IntegerLiteral = Struct.new(:value, keyword_init: true)
        FloatLiteral   = Struct.new(:value, keyword_init: true)
        StringLiteral  = Struct.new(:value, keyword_init: true)
        BoolLiteral    = Struct.new(:value, keyword_init: true)
        # A plain class, not `Struct.new(keyword_init: true)` — every
        # sibling leaf node here carries at least one field, but this
        # one carries none by nature (a nil literal has no data to
        # hold), and `Struct.new` with zero member names ahead of
        # `keyword_init:` is real, live Ruby-version-dependent
        # behavior: works on 3.3, raises "wrong number of arguments
        # (given 0, expected 1+)" on 3.2 (caught deploying to Lambda's
        # own ruby3.2 runtime). `.new`/`case ... when NilLiteral` below
        # are the only two things this type is ever used for, and a
        # bare class answers both identically.
        NilLiteral     = Class.new
        Addition       = Struct.new(:left, :right, keyword_init: true)
        SignTest       = Struct.new(:operator, :test, :receiver, keyword_init: true)
        Empty          = Struct.new(:receiver, keyword_init: true)
        ToS            = Struct.new(:receiver, keyword_init: true)
        Modulo         = Struct.new(:receiver, :divisor, keyword_init: true)
        Size           = Struct.new(:receiver, keyword_init: true)
        Lookup         = Struct.new(:path, keyword_init: true)

        # `receiver.match?(/pattern/)` -- vendored addition, not (yet)
        # upstream hecksagain (migration plan task 8): confirmed the
        # SINGLE most impactful corpus-wide dispatch-time gap of the
        # whole migration -- `.match?(regex)` appears in nearly every
        # value_object's format-validation rule across every corpus
        # this migration touched (email/phone/ISO-8601-timestamp/zip
        # patterns, dozens of files), and had NO parse support at all:
        # it fell all the way through to the `Lookup` catch-all below,
        # which tried to split the ENTIRE ".match?(/\A\d{5}\z/)" text
        # on "." as if it were a dotted attribute path, and crashed with
        # an opaque "no implicit conversion of Symbol into Integer"
        # somewhere downstream -- confirmed live via a real dispatch,
        # not validate (validate never evaluates a predicate body).
        # `receiver` still needs its own parse (it may itself be a
        # dotted lookup, e.g. `some_field.match?(...)`), the pattern
        # text is taken as-is between the slashes (a Ruby Regexp literal,
        # not the evaluator's own mini-grammar -- there is nothing to
        # recurse into).
        MatchesRegex   = Struct.new(:receiver, :pattern, :flags, keyword_init: true)

        # `.present?`/`.blank?` -- vendored addition, not (yet) upstream
        # hecksagain (migration plan task 8): the second-most pervasive
        # gap this pass found, right behind `.match?` -- confirmed real
        # via the same "no such attribute" Lookup-fallback crash, since
        # neither suffix existed in this leaf grammar at all. Rails-
        # standard semantics (blank = nil, or responds_to?(:empty?) &&
        # empty? ; present = !blank), not just `!nil?` -- matches what
        # every corpus author actually means by `.present?` on a string
        # field that could legitimately be "" rather than absent.
        Presence       = Struct.new(:receiver, :negated, keyword_init: true)

        # `receiver.split("SEP")` -- vendored addition, not (yet) upstream
        # hecksagain (migration plan task 9): confirmed the single
        # highest-value new finding of the real-dispatch smoke sweep --
        # the bus's own core `Phrase` value object (dispatch/lexicon/
        # query/command_bus.bluebook, all four storehouse-kernel files,
        # byte-identical text) validates its four-segment shape with
        # `value.split("::").length == 4 && value.split("::").all? { |s|
        # s.length > 0 }` -- `.split(` matched none of this grammar's
        # known suffixes, so it fell through to the `Lookup` catch-all,
        # which split the RAW EXPRESSION TEXT on "." (not the runtime
        # value) and crashed with `TypeError: no implicit conversion of
        # Symbol into Integer` the moment `String#[]` was handed a
        # Symbol segment -- meaning every command taking a Phrase was
        # entirely undispatchable, confirmed live via `Lexicon::Lexicon.
        # Lookup`/`Query::Query.Run`, not inferred. Produces a real
        # Array, deliberately not a scalar -- `.length`/`.all?` compose
        # with it below the same way they compose with any other
        # receiver, because `parse` recurses on the receiver text and
        # the existing `Size` node (`.length`/`.size`) already treats
        # "whatever `interpret` returns" as its receiver's value, not a
        # fixed type. Separator is taken literally between the quotes,
        # same "no sub-grammar to recurse into" precedent `MatchesRegex`
        # already set for its own `/pattern/` text above.
        Split          = Struct.new(:receiver, :separator, keyword_init: true)

        # `receiver.last` -- vendored addition, not (yet) upstream
        # hecksagain (migration plan task 9), same pass as `Split` above
        # and built for the same `Phrase`/`Path` value objects --
        # `Query::Phrase`'s own invariant chains `.split("::").last.
        # match?(...)` to check the fourth segment's casing. Same shape
        # as `.length`/`.size` (Size) and `.empty?` (Empty) -- a plain
        # receiver-in, scalar-out accessor, no sub-grammar of its own.
        Last           = Struct.new(:receiver, keyword_init: true)

        # `receiver.all? { |x| PREDICATE }` / `.any? { ... }` / `.none? {
        # ... }` -- vendored addition, not (yet) upstream hecksagain
        # (migration plan task 9), completing the same `Phrase`
        # four-segment invariant the `Split` node above was built for
        # (`value.split("::").all? { |s| s.length > 0 }`). Structurally
        # different from every other addition in this file: every prior
        # suffix is a flat receiver -> scalar transform, but a block
        # predicate needs to evaluate its own sub-expression ONCE PER
        # ELEMENT with the block parameter bound to that element. Kept
        # minimal per the migration plan's own instruction -- no
        # persistent iteration-variable concept added to Resolver's
        # state model at all ; `predicate` below is a fully-parsed
        # EVALUATOR ast (not a Resolver ast -- the predicate is a
        # boolean/comparison expression like `s.length > 0`, exactly the
        # grammar `Bluebook::Expression::Evaluator` owns, not this
        # module's own leaf grammar), parsed once at `parse`-time same as
        # every sibling node's sub-expressions are. `mode` distinguishes
        # all?/any?/none? without three duplicated node types, since
        # their only difference is which Array predicate aggregates the
        # per-element results (interpret_with_element, below, is the
        # "smallest correct thing" the plan asked for -- it threads the
        # element binding through a temporarily-extended `attrs` hash for
        # that one predicate's evaluation only, never touching
        # `interpret`'s own signature or any other node's call sites).
        # `Resolver` already calls into `Evaluator` elsewhere in this
        # file (`sign_test_node`/`apply_sign_test` call `Evaluator.
        # apply`/`Evaluator::OPERATORS` directly) -- this is the same
        # precedented cross-reference, not a new coupling.
        BlockPredicate = Struct.new(:mode, :receiver, :param, :predicate, keyword_init: true)

        # Which Array method each block-predicate suffix maps to, and
        # which Ruby Enumerable method decides the aggregate result --
        # declared as data, not a three-way `case`, the same shape
        # SIGN_TEST_OPERATORS above already uses for its own suffix
        # family.
        BLOCK_PREDICATE_MODES = {
          "all?"  => :all,
          "any?"  => :any,
          "none?" => :none
        }.freeze

        # `receiver.start_with?("prefix")` / `receiver.end_with?("suffix")`
        # -- vendored addition, not (yet) upstream hecksagain (migration
        # plan task 9), the sibling gap the `Split`/`Last`/`BlockPredicate`
        # pass above flagged and deliberately left unfixed --
        # `Query::Query.Run`/`Dispatch::Dispatch.Route`/`CommandBus::
        # CommandBus.Route`'s shared `Params` value object validates its
        # JSON-object shape with `value.start_with?("{") && value.
        # end_with?("}")` (dispatch/query/command_bus.bluebook, all three
        # storehouse-kernel files, byte-identical text) -- `.start_with?(`/
        # `.end_with?(` matched none of this grammar's known suffixes, so
        # both fell through to the `Lookup` catch-all and crashed with the
        # identical `TypeError: no implicit conversion of Symbol into
        # Integer` shape `.split`/`.all?` used to, confirmed live via a
        # real dispatch (not validate), not inferred. Two separate node
        # types rather than one `mode:`-keyed struct (the `BlockPredicate`/
        # `SignTest` precedent) -- `start_with?`/`end_with?` aren't two
        # spellings of the same test the way `all?`/`any?`/`none?` are (one
        # Array-aggregation family) or `positive?`/`negative?`/`zero?` are
        # (one comparison-against-0 family) ; they check different ends of
        # the same string and share nothing but their
        # receiver-plus-literal-argument shape. `substring` is taken
        # literally between the quotes, same "no sub-grammar to recurse
        # into" precedent `Split`'s `separator`/`MatchesRegex`'s `pattern`
        # already set.
        StartsWith = Struct.new(:receiver, :substring, keyword_init: true)
        EndsWith   = Struct.new(:receiver, :substring, keyword_init: true)

        module_function

        def resolve(expr, state, attrs)
          interpret(parse(expr), state, attrs)
        end

        def parse(expr)
          expr = expr.to_s.strip

          return Size.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.length\z/

          return IntegerLiteral.new(value: Integer(expr, 10)) if expr.match?(/\A-?\d+\z/)
          return FloatLiteral.new(value: Float(expr))         if expr.match?(/\A-?\d*\.\d+\z/)
          return StringLiteral.new(value: expr[1..-2])        if quoted?(expr)
          return BoolLiteral.new(value: true)                 if expr == "true"
          return BoolLiteral.new(value: false)                if expr == "false"
          return NilLiteral.new                                if expr == "nil"

          arithmetic = split_addition(expr)
          return Addition.new(left: parse(arithmetic[0]), right: parse(arithmetic[1])) if arithmetic

          sign = match_suffix(expr, SIGN_TESTS)
          return sign_test_node(sign) if sign

          return Empty.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.empty\?\z/
          return ToS.new(receiver: parse(Regexp.last_match(1)))   if expr =~ /\A(.+)\.to_s\z/

          modulo = match_call(expr, ".modulo(")
          return Modulo.new(receiver: parse(modulo[0]), divisor: parse(modulo[1])) if modulo

          return Size.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.size\z/

          if expr =~ /\A(.+)\.match\?\(\/(.*)\/([a-z]*)\)\z/m
            return MatchesRegex.new(receiver: parse(Regexp.last_match(1)),
                                     pattern: Regexp.last_match(2),
                                     flags: Regexp.last_match(3))
          end

          return Presence.new(receiver: parse(Regexp.last_match(1)), negated: false) if expr =~ /\A(.+)\.present\?\z/
          return Presence.new(receiver: parse(Regexp.last_match(1)), negated: true)  if expr =~ /\A(.+)\.blank\?\z/

          if expr =~ /\A(.+)\.split\("([^"]*)"\)\z/
            return Split.new(receiver: parse(Regexp.last_match(1)), separator: Regexp.last_match(2))
          end

          return Last.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.last\z/

          if expr =~ /\A(.+)\.start_with\?\("([^"]*)"\)\z/
            return StartsWith.new(receiver: parse(Regexp.last_match(1)), substring: Regexp.last_match(2))
          end

          if expr =~ /\A(.+)\.end_with\?\("([^"]*)"\)\z/
            return EndsWith.new(receiver: parse(Regexp.last_match(1)), substring: Regexp.last_match(2))
          end

          block_predicate = parse_block_predicate(expr)
          return block_predicate if block_predicate

          Lookup.new(path: expr)
        end

        # `.all?`/`.any?`/`.none?` -- vendored addition, see the
        # `BlockPredicate` struct's own comment above. Matched last among
        # the suffix rules (right before the `Lookup` catch-all) since
        # its own predicate text can itself contain almost anything a
        # leaf expression can -- letting every more specific rule above
        # try first avoids this one accidentally swallowing a receiver
        # another rule was meant to parse. `receiver` and the predicate
        # body are each parsed through their OWN correct grammar --
        # `parse` (this module's leaf grammar) for the receiver, `
        # Evaluator.parse` (the boolean/comparison grammar) for the
        # predicate, since a predicate like `s.length > 0` is a
        # comparison, not a bare leaf.
        def parse_block_predicate(expr)
          BLOCK_PREDICATE_MODES.each do |suffix, mode|
            match = expr.match(/\A(.+)\.#{Regexp.escape(suffix)}\s*\{\s*\|(\w+)\|\s*(.+?)\s*\}\z/m)
            next unless match

            return BlockPredicate.new(
              mode: mode,
              receiver: parse(match[1]),
              param: match[2],
              predicate: Evaluator.parse(match[3])
            )
          end
          nil
        end

        def sign_test_node(parts)
          receiver, test = parts
          symbol   = SIGN_TEST_OPERATORS.fetch(test)
          operator = Evaluator::OPERATORS.find { |candidate| candidate.symbol == symbol }
          SignTest.new(operator: operator, test: test, receiver: parse(receiver))
        end

        def interpret(node, state, attrs)
          case node
          when IntegerLiteral, FloatLiteral, StringLiteral, BoolLiteral then node.value
          when NilLiteral then nil
          when Addition
            add(interpret(node.left, state, attrs), interpret(node.right, state, attrs))
          when SignTest
            apply_sign_test(node, interpret(node.receiver, state, attrs))
          when Empty
            emptiness_of(interpret(node.receiver, state, attrs))
          when ToS
            string_of(interpret(node.receiver, state, attrs))
          when Modulo
            apply_modulo(interpret(node.receiver, state, attrs), interpret(node.divisor, state, attrs))
          when Size
            size_of(interpret(node.receiver, state, attrs))
          when MatchesRegex
            matches_regex?(interpret(node.receiver, state, attrs), node.pattern, node.flags)
          when Presence
            present = !blank?(interpret(node.receiver, state, attrs))
            node.negated ? !present : present
          when Split
            split_value(interpret(node.receiver, state, attrs), node.separator)
          when Last
            last_of(interpret(node.receiver, state, attrs))
          when StartsWith
            starts_with?(interpret(node.receiver, state, attrs), node.substring)
          when EndsWith
            ends_with?(interpret(node.receiver, state, attrs), node.substring)
          when BlockPredicate
            evaluate_block_predicate(node, interpret(node.receiver, state, attrs), state, attrs)
          when Lookup
            lookup(node.path, state, attrs)
          end
        end

        # `.present?`/`.blank?` -- vendored addition, see the
        # `Presence` struct's own comment above. `nil` and `false` are
        # blank ; a String/Array/Hash is blank when EMPTY, not merely
        # falsy -- a VO-wrapped field that IS assigned (`{value: "x"}`,
        # `Value#to_h`'d first) is present regardless of what its own
        # inner value holds, matching how every VO-typed field in this
        # corpus is actually shaped once set at all.
        def blank?(value)
          return true if value.nil? || value == false

          # Duck-typed, not `value.is_a?(Runtime::Value)` -- this module
          # is `Bluebook::Expression`, a different namespace tree from
          # `Runtime::Value` entirely, and reaching across for a single
          # class check is the exact cross-module coupling that already
          # broke `Modulo`'s own `match_call` reference elsewhere in
          # this file (found live while building this fix, not assumed).
          value = value.to_h if value.respond_to?(:to_h) && !value.is_a?(Hash)
          case value
          when String, Array, Hash then value.empty?
          else false
          end
        end

        # `receiver.match?(/pattern/)` -- vendored addition, see the
        # `MatchesRegex` struct's own comment above. `receiver_value` is
        # coerced to a plain String first -- inlined here rather than
        # calling `Evaluator#string_of` (a DIFFERENT module_function
        # module; not actually in scope from inside Resolver despite
        # `Modulo`'s own parse rule above calling a same-named
        # `match_call` that has the identical cross-module problem --
        # found live while building this, not assumed).
        def matches_regex?(receiver_value, pattern, flags)
          text = case receiver_value
                 when String, Symbol      then receiver_value.to_s
                 when Integer, Float      then receiver_value.to_s
                 when NilClass             then ""
                 else
                   raise EvaluationError, "match? expects a scalar, got #{receiver_value.class}"
                 end

          options = 0
          options |= Regexp::IGNORECASE if flags.include?("i")
          options |= Regexp::MULTILINE  if flags.include?("m")
          options |= Regexp::EXTENDED   if flags.include?("x")

          Regexp.new(pattern, options).match?(text)
        end

        def split_addition(expr)
          depth = 0
          quote = nil

          expr.each_char.with_index do |char, index|
            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            elsif char == "("
              depth += 1
            elsif char == ")"
              depth -= 1
            elsif char == "+" && depth.zero?
              return [expr[0...index].strip, expr[(index + 1)..].strip]
            end
          end
          nil
        end

        def add(left, right)
          require_number(left, "addition") + require_number(right, "addition")
        end

        def quoted?(expr)
          return false if expr.length < 2

          (expr.start_with?('"') && expr.end_with?('"')) ||
            (expr.start_with?("'") && expr.end_with?("'"))
        end

        # Declared the same way in Vocabulary::SizedType
        # (language/bluebook/vocabulary.bluebook) — spec/vocabulary_conformance_spec
        # holds this equal to the language. Shared by .size and .empty?,
        # which admit the same set for the same reason.
        SIZED_TYPES = %w[Array String Hash].freeze

        def size_of(value)
          return value.size if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "size expects a list or string, got #{describe(value)}"
        end

        def emptiness_of(value)
          return value.empty? if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "empty? expects a list or string, got #{describe(value)}"
        end

        # `.split("SEP")` -- vendored addition, see the `Split` struct's
        # own comment above. Only a String receiver makes sense to
        # split -- unlike `.length`/`.size`/`.empty?`, which are already
        # meaningful over Array/Hash too, `.split` is a String-only
        # method in the corpus's own usage (every occurrence found this
        # pass splits a Phrase's own string value).
        def split_value(value, separator)
          raise EvaluationError, "split expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.split(separator)
        end

        # `.last` -- vendored addition, see the `Last` struct's own
        # comment above. Duck-typed on `respond_to?(:last)` rather than
        # hard-coding Array -- the one corpus usage found this pass
        # (`Query::Phrase`'s `.split("::").last`) always receives a
        # `Split`-produced Array, but nothing about `.last` itself is
        # Array-specific, and this matches `Empty`/`Size`'s own
        # duck-typed-over-a-known-set precedent without inventing a
        # narrower rule than the method needs.
        def last_of(value)
          return value.last if value.respond_to?(:last)

          raise EvaluationError, "last expects a list, got #{describe(value)}"
        end

        # `.start_with?("prefix")` -- vendored addition, see the
        # `StartsWith` struct's own comment above. String-only, same
        # reasoning as `.split` above -- every corpus usage found this
        # pass (`Params`'s own JSON-object-shape invariant) receives a
        # plain String field.
        def starts_with?(value, substring)
          raise EvaluationError, "start_with? expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.start_with?(substring)
        end

        # `.end_with?("suffix")` -- vendored addition, see the `EndsWith`
        # struct's own comment above. Same String-only reasoning as
        # `start_with?` immediately above.
        def ends_with?(value, substring)
          raise EvaluationError, "end_with? expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.end_with?(substring)
        end

        # `.all?`/`.any?`/`.none?` -- vendored addition, see the
        # `BlockPredicate` struct's own comment above. `collection` is
        # already-interpreted (a real Array, produced by whatever
        # receiver expression came before it -- typically `Split`'s
        # output), so this only has to run the per-element predicate and
        # aggregate. `interpret_with_element` is the "smallest correct
        # thing" the migration plan asked for : no persistent iteration-
        # variable concept added anywhere else in Resolver's state model,
        # just `attrs` extended with the bound name for the span of that
        # one predicate evaluation, discarded immediately after.
        def evaluate_block_predicate(node, collection, state, attrs)
          unless collection.is_a?(Array)
            raise EvaluationError, "#{node.mode}? expects a list, got #{describe(collection)}"
          end

          outcomes = collection.map { |element| interpret_with_element(node, element, state, attrs) }

          case node.mode
          when :all  then outcomes.all?
          when :any  then outcomes.any?
          when :none then outcomes.none?
          end
        end

        # Binds the block parameter for exactly one element's predicate
        # evaluation -- `attrs` wins over `state` in `fetch` (see below),
        # so the bound name shadows any same-named state/attrs field for
        # the span of this one call only ; nothing persists past it.
        def interpret_with_element(node, element, state, attrs)
          Evaluator.interpret(node.predicate, state, attrs.merge(node.param.to_sym => element))
        end

        # Declared the same way in Vocabulary::ToStringType
        # (language/bluebook/vocabulary.bluebook) — spec/vocabulary_conformance_spec
        # holds this equal to the language.
        TO_STRING_TYPES = %w[String Integer Float TrueClass FalseClass NilClass].freeze

        def string_of(value)
          case value
          when String                then value
          when Integer, Float        then value.to_s
          when TrueClass, FalseClass then value.to_s
          when NilClass              then ""
          else
            raise EvaluationError, "to_s expects a scalar, got #{describe(value)}"
          end
        end

        def match_suffix(expr, suffixes)
          suffixes.each do |suffix|
            marker = ".#{suffix}"
            return [expr[0...-marker.length], suffix] if expr.end_with?(marker)
          end
          nil
        end

        def apply_sign_test(node, value)
          number = numeric(value)
          raise EvaluationError, "#{node.test} expects a number, got #{describe(value)}" unless number

          Evaluator.apply(node.operator, number, 0)
        end

        def match_call(expr, marker)
          index = expr.rindex(marker)
          return nil unless index && expr.end_with?(")")

          [expr[0...index], expr[(index + marker.length)...-1]]
        end

        def apply_modulo(receiver_value, divisor_value)
          divisor = require_number(divisor_value, "modulo")
          raise EvaluationError, "divided by 0" if divisor.zero?

          require_number(receiver_value, "modulo").to_i % divisor.to_i
        end

        def lookup(expr, state, attrs)
          return fetch(expr, state, attrs) unless expr.include?(".")

          head, *rest = expr.split(".")
          rest.reduce(fetch(head, state, attrs)) do |value, segment|
            break nil unless value.respond_to?(:[])

            value[segment.to_sym] || value[segment]
          end
        end

        def fetch(name, state, attrs)
          key = name.to_sym
          return attrs[key] if attrs.key?(key)
          return state[key] if known?(state, key)

          raise EvaluationError, "cannot resolve #{name.inspect} — no such attribute or argument"
        end

        def known?(state, key)
          return state.key?(key) if state.respond_to?(:key?)

          !state[key].nil?
        end

        def numeric(value)
          value if value.is_a?(Integer) || value.is_a?(Float)
        end

        def require_number(value, operation)
          numeric(value) ||
            raise(EvaluationError, "#{operation} expects a number, got #{describe(value)}")
        end

        def describe(value) = Rendering.describe(value)
      end
    end
  end
end

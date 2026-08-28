require "json"
require_relative "../../rendering"
require_relative "../../vocabulary"
require_relative "resolver/block_predicates"

module Hecks
  module Bluebook
    module Expression
      class EvaluationError < StandardError; end

      module Resolver
        SIGN_TESTS = Hecks::Vocabulary.fetch("SignTest")

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
        # `["active", "suspended"]` — a literal set, the haystack half of
        # an `.include?`. Vocabulary::IncludeHaystack has always ADMITTED
        # Array (and Evaluator#includes? has always had a `when Array`
        # arm), but nothing could produce one: there was no array-literal
        # node, so `["a", "b"].include?(x)` fell through to Lookup and
        # refused with `cannot resolve "[\"a\", \"b\"]"`. A declared
        # capability with no way to spell it.
        ArrayLiteral   = Struct.new(:elements, keyword_init: true)
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

        # UPDATE 2026-08-27: every "vendored addition, not (yet) upstream
        # hecks" comment on this file's own MatchesRegex/Presence/Split/
        # First/Last/StartsWith/EndsWith below (plus ArrayLiteral above)
        # described a REAL gap, found the hard way, in the history each
        # comment tells — and that history stays exactly as written,
        # on purpose. What changed is the PRESENT TENSE claim "not (yet)
        # upstream": a review of this exact migration found these eight
        # symbols had working Ruby parse/interpret arms but had NEVER
        # gone through Propose -> Render -> Admit
        # (lib/hecks/grammar/expression_operators.json) the way every
        # other operator here has — a closed-vocabulary guard
        # (spec/operator_conformance_spec.rb) built entirely over TABLES
        # structurally could not see hand-coded Struct/parse/interpret
        # additions, so eight operators ran in Ruby, admitted nowhere,
        # invisible to the one guard whose whole job was "reads in every
        # target." All eight are now ledger-admitted for real, with full
        # Rust kernel parity (rust/src/kernel/expression_operators/
        # {pattern_match,presence,text,positional}.rs) — the two-tier
        # gap is closed, not merely tracked.
        #
        # `receiver.match?(/pattern/)` -- vendored addition, not (yet)
        # upstream hecks (migration plan task 8): confirmed the
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
        # hecks (migration plan task 8): the second-most pervasive
        # gap this pass found, right behind `.match?` -- confirmed real
        # via the same "no such attribute" Lookup-fallback crash, since
        # neither suffix existed in this leaf grammar at all. Rails-
        # standard semantics (blank = nil, or responds_to?(:empty?) &&
        # empty? ; present = !blank), not just `!nil?` -- matches what
        # every corpus author actually means by `.present?` on a string
        # field that could legitimately be "" rather than absent.
        Presence       = Struct.new(:receiver, :negated, keyword_init: true)

        # `.set?`/`.unset?` -- sibling of `.present?`/`.blank?` immediately
        # above, added for a DELIBERATELY narrower question, spelled out in
        # the name so choosing between the two pairs is a choice, not a
        # trap: `.present?` means "not EMPTY" (Rails-standard -- nil/false,
        # and an EMPTY String/Array/Hash, are blank; nothing else is),
        # which quietly answers "was this ever assigned" and "does the
        # assigned value happen to be empty" as the SAME question. For an
        # optional field whose only legitimate unset state IS nil, that
        # conflation is a real trap -- confirmed live: a corpus author
        # reaching for `superseded_by.blank?` to guard an optional
        # reference burned real time before landing on "just don't guard
        # it," because `.blank?` cannot be asked to mean ONLY "was this
        # never assigned." `.set?`/`.unset?` ask exactly that, and nothing
        # else: `!receiver.nil?`, full stop -- an assigned-but-empty
        # String/Array/Hash (or a VO wrapping one) is `.set?`, not
        # `.unset?`, unlike `.blank?`'s own reading of the identical value.
        Assignment     = Struct.new(:receiver, :negated, keyword_init: true)

        # `receiver.split("SEP")` -- vendored addition, not (yet) upstream
        # hecks (migration plan task 9): confirmed the single
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
        # hecks (migration plan task 9), same pass as `Split` above
        # and built for the same `Phrase`/`Path` value objects --
        # `Query::Phrase`'s own invariant chains `.split("::").last.
        # match?(...)` to check the fourth segment's casing. Same shape
        # as `.length`/`.size` (Size) and `.empty?` (Empty) -- a plain
        # receiver-in, scalar-out accessor, no sub-grammar of its own.
        Last           = Struct.new(:receiver, keyword_init: true)

        # `receiver.first` -- sibling addition to `Last` immediately
        # above, same shape, same vendored-not-upstream status. Added
        # for the shipping domain's `legs.first` (an itinerary's
        # departure leg), the exact mirror of `legs.last` (its arrival
        # leg) that domain already leaned on -- `Last`'s own duck-typed-
        # on-`respond_to?` reasoning applies unchanged, so `first_of`
        # below is `last_of` with the one method swapped, not a new
        # design.
        First          = Struct.new(:receiver, keyword_init: true)

        # `receiver.start_with?("prefix")` / `receiver.end_with?("suffix")`
        # -- vendored addition, not (yet) upstream hecks (migration
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
          return NilLiteral.new if expr == "nil"

          elements = array_elements(expr)
          return ArrayLiteral.new(elements: elements.map { |element| parse(element) }) if elements

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
                                    pattern:  Regexp.last_match(2),
                                    flags:    Regexp.last_match(3))
          end

          return Presence.new(receiver: parse(Regexp.last_match(1)), negated: false) if expr =~ /\A(.+)\.present\?\z/
          return Presence.new(receiver: parse(Regexp.last_match(1)), negated: true)  if expr =~ /\A(.+)\.blank\?\z/

          return Assignment.new(receiver: parse(Regexp.last_match(1)), negated: false) if expr =~ /\A(.+)\.set\?\z/
          return Assignment.new(receiver: parse(Regexp.last_match(1)), negated: true)  if expr =~ /\A(.+)\.unset\?\z/

          if expr =~ /\A(.+)\.split\("([^"]*)"\)\z/
            return Split.new(receiver: parse(Regexp.last_match(1)), separator: Regexp.last_match(2))
          end

          return First.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.first\z/
          return Last.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.last\z/

          if expr =~ /\A(.+)\.start_with\?\("([^"]*)"\)\z/
            return StartsWith.new(receiver: parse(Regexp.last_match(1)), substring: Regexp.last_match(2))
          end

          if expr =~ /\A(.+)\.end_with\?\("([^"]*)"\)\z/
            return EndsWith.new(receiver: parse(Regexp.last_match(1)), substring: Regexp.last_match(2))
          end

          block_opener = parse_block_opener(expr)
          return block_opener if block_opener

          Lookup.new(path: expr)
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
          when ArrayLiteral then node.elements.map { |element| interpret(element, state, attrs) }
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
          when Assignment
            set = !interpret(node.receiver, state, attrs).nil?
            node.negated ? !set : set
          when Split
            split_value(interpret(node.receiver, state, attrs), node.separator)
          when Last
            last_of(interpret(node.receiver, state, attrs))
          when First
            first_of(interpret(node.receiver, state, attrs))
          when Find
            found_of(node, interpret(node.receiver, state, attrs), state, attrs)
          when StartsWith
            starts_with?(interpret(node.receiver, state, attrs), node.substring)
          when EndsWith
            ends_with?(interpret(node.receiver, state, attrs), node.substring)
          when BlockPredicate
            evaluate_block_predicate(node, interpret(node.receiver, state, attrs), state, attrs)
          when Lookup
            lookup(node.path, state, attrs)
          else
            # Every leaf node `parse` can produce has a `when` above —
            # a backstop against the day this grammar grows a new leaf
            # type (this file's own history: MatchesRegex/Presence/
            # Split/Last/First/Find/StartsWith/EndsWith/BlockPredicate
            # were each added exactly this way, and each one — before it had an
            # `interpret` arm — fell all the way through to the
            # `Lookup` catch-all in `parse` and crashed downstream with
            # an opaque type error, never here). A missing arm here
            # would instead return bare `nil` silently, the one wrong-
            # answer shape this leaf grammar has otherwise never
            # allowed.
            raise EvaluationError, "no interpreter handles #{node.class} — add a case before parse can produce it"
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
                 when String, Symbol then receiver_value.to_s
                 when Integer, Float then receiver_value.to_s
                 when NilClass then ""
                 else
                   raise EvaluationError, "match? expects a scalar, got #{receiver_value.class}"
                 end

          options = 0
          options |= Regexp::IGNORECASE if flags.include?("i")
          options |= Regexp::MULTILINE  if flags.include?("m")
          options |= Regexp::EXTENDED   if flags.include?("x")

          Regexp.new(pattern, options).match?(text)
        rescue RegexpError => e
          # M9: a malformed pattern between the slashes (an unclosed
          # character class, say) is a defect in the EXPRESSION TEXT
          # itself, exactly the same category of author mistake an
          # unresolvable attribute name already refuses for — `Regexp.new`
          # raising a raw `RegexpError` crossed this sublanguage's own
          # refusal boundary the same way the `ZeroDivisionError`/
          # `TypeError` cases elsewhere in this file did.
          raise EvaluationError, "match? given an invalid pattern #{pattern.inspect} — #{e.message}"
        end

        # The elements of a bracketed literal, or nil if this isn't one.
        # Splits on TOP-LEVEL commas only — quote-aware and depth-aware,
        # the same discipline `split_addition` already applies, so a
        # nested array or a comma inside a string element stays whole.
        def array_elements(expr)
          return nil unless expr.start_with?("[") && expr.end_with?("]")

          inner = expr[1..-2].strip
          return [] if inner.empty?

          elements = []
          depth = 0
          quote = nil
          current = +""
          inner.each_char do |char|
            if quote
              quote = nil if char == quote
              current << char
              next
            end
            case char
            when '"', "'" then quote = char
            when "[", "(" then depth += 1
            when "]", ")" then depth -= 1
            end
            if char == "," && depth.zero?
              elements << current.strip
              current = +""
            else
              current << char
            end
          end
          elements << current.strip
          elements.reject(&:empty?)
        end

        # BRACES COUNT TOWARD DEPTH, exactly as parens do — a `+` inside a
        # block predicate's own `{ |x| ... }` body is not this expression's
        # own addition. `parse` tries addition BEFORE `parse_block_opener`,
        # so a paren-only depth count split
        #   kings.any? { |k| k.square.file == to.file + 1 && ... }
        # at that inner `+`, turning the whole expression into a nonsense
        # Addition whose left operand then walked "any? { |k| k" into an
        # Array as an attribute path — "TypeError: no implicit conversion
        # of Symbol into Integer", the same signature every unsupported
        # construct raises, which is what let this hide. Found live in a
        # downstream chess domain's castling given; the evaluator's own
        # top_level_index has counted braces since its own version of this
        # exact lesson.
        def split_addition(expr)
          depth = 0
          quote = nil

          expr.each_char.with_index do |char, index|
            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            # `[`/`]` -- the identical lesson this method's own `(`/`{`
            # comment already names, a third time (found live via the
            # type-directed bounded-exhaustive expression generator,
            # Phase 7 of the equivalence-gap plan): `ArrayLiteral` can
            # appear as a general sub-expression now, not only as
            # `.include?`'s own haystack, so an array element containing
            # its own top-level `+` (`[0, 0 + 0]`) used to read as THIS
            # expression's own addition split point -- the whole
            # receiver before `.all?`/`.any?`/etc. torn in half before
            # `parse_block_opener` ever saw it as one atomic leaf.
            elsif ["(", "{", "["].include?(char)
              depth += 1
            elsif [")", "}", "]"].include?(char)
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
        SIZED_TYPES = Hecks::Vocabulary.fetch("SizedType")

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

        # `.first` -- see the `First` struct's own comment above.
        # `last_of` with the one method swapped, same duck-typed
        # reasoning.
        def first_of(value)
          return value.first if value.respond_to?(:first)

          raise EvaluationError, "first expects a list, got #{describe(value)}"
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

        # Declared the same way in Vocabulary::ToStringType
        # (language/bluebook/vocabulary.bluebook) — spec/vocabulary_conformance_spec
        # holds this equal to the language.
        TO_STRING_TYPES = Hecks::Vocabulary.fetch("ToStringType")

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

        # FOUND LIVE via the type-directed bounded-exhaustive expression
        # generator (Phase 7, equivalence-gap plan — spec/
        # bounded_exhaustive_expression_spec.rb): `.modulo(`'s own
        # argument position accepts any numeric sub-expression, including
        # ANOTHER `.modulo(...)` call — `0.modulo(num_b.modulo(-1))` is
        # perfectly well-typed — but `expr.rindex(marker)` finds the
        # RIGHTMOST (innermost) `.modulo(` in the whole string, not the
        # OUTERMOST one a nested call needs split at. For that expression
        # it found the INNER `.modulo(` (inside `num_b.modulo(-1)`) and
        # split there, producing a receiver of `"0.modulo(num_b"` and a
        # divisor of `"-1)"` — both garbage, both re-parsed as bogus
        # `Lookup` paths, both then refusing with "cannot resolve" — a
        # SILENT MISPARSE that happened to fail safe into a real
        # `EvaluationError` rather than a raw crash, which is exactly why
        # this had gone unnoticed: nothing before this generator existed
        # ever fed `.modulo` a nested `.modulo` call, random fuzzing
        # essentially never manufactures that specific shape by chance,
        # and the resulting refusal LOOKS like an ordinary, correct one
        # unless you already know every name this generator's own
        # synthetic state declares (real corpus authors would see this as
        # a mysterious "cannot resolve" on text they never wrote).
        #
        # Fixed the same way `split_addition`/`Evaluator.top_level_index`
        # already handle nested `(`/`{` elsewhere in this exact file:
        # find the FIRST (leftmost, outermost) occurrence of the marker,
        # then track paren/quote depth from there to find ITS OWN
        # matching close — not just strip the string's own trailing `)`
        # and hope it belongs to this call.
        # Not just the FIRST occurrence, either — `.modulo` also CHAINS
        # (`x.modulo(a).modulo(b)`, the receiver of the OUTER call itself
        # ending in a `.modulo(...)` call), a second real shape the
        # leftmost-occurrence-only version of this fix still mis-parsed:
        # the first `.modulo(`'s own matching close paren lands mid-
        # string (right after `a)`, before the second `.modulo(b)`), so
        # it correctly fails the "reaches the end" check below and must
        # be tried again at the NEXT occurrence rather than giving up.
        # Trying occurrences strictly left to right and taking the FIRST
        # one whose matching close reaches the string's last character
        # handles both shapes with the same rule: for NESTING
        # (`.modulo(x.modulo(y))`), the leftmost (outer) occurrence's own
        # paren-depth tracking already walks straight through the inner
        # call to the true final `)`; for CHAINING, the leftmost
        # occurrence's close lands short and is rejected, so the next
        # occurrence (the true outermost call) is tried instead.
        def match_call(expr, marker)
          start = 0
          while (index = expr.index(marker, start))
            close = matching_paren(expr, index + marker.length)
            return [expr[0...index], expr[(index + marker.length)...close]] if close == expr.length - 1

            start = index + 1
          end
          nil
        end

        # `matching_brace` (resolver/block_predicates.rb)'s own twin, one
        # bracket pair over: `start` is the index just past the OPENING
        # `(` already consumed by the caller (depth starts at 1, not 0,
        # for the same reason).
        def matching_paren(expr, start)
          depth = 1
          quote = nil
          index = start
          while index < expr.length
            char = expr[index]
            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            elsif char == "("
              depth += 1
            elsif char == ")"
              depth -= 1
              return index if depth.zero?
            end
            index += 1
          end
          nil
        end

        # Both operands are coerced to a real Integer/Float BEFORE the
        # zero-check, and the check reads the COERCED divisor — not the
        # raw `divisor_value` (which might not even respond to `.zero?`,
        # a String for instance) and not a `.to_i`-truncated stand-in for
        # it either. The old order checked a truncated `divisor.to_i`
        # AFTER already validating the untruncated value wasn't zero, so
        # a divisor merely small (`0.3`, truncating to `0`) sailed past
        # the guard and then blew up `Integer#%` with a raw
        # `ZeroDivisionError` the moment it reached zero anyway.
        #
        # The modulo itself is plain `%` on the coerced values, matching
        # `add`'s own no-truncation precedent just above — Ruby's native
        # `%` already handles every Integer/Float combination correctly
        # (promoting to Float when either side is one), so rounding both
        # operands down to Integer first was pure data loss with no
        # purpose: `7.5.modulo(2.5)` silently became `7 % 2` (`1`)
        # instead of the real `0.0`.
        def apply_modulo(receiver_value, divisor_value)
          receiver = require_number(receiver_value, "modulo")
          divisor  = require_number(divisor_value, "modulo")
          raise EvaluationError, "divided by 0" if divisor.zero?

          receiver % divisor
        end

        def lookup(expr, state, attrs)
          return unwrap_scalar(fetch(expr, state, attrs)) unless expr.include?(".")

          head, *rest = expr.split(".")
          unwrap_scalar(walk_path(fetch(head, state, attrs), rest))
        end

        # Walks a list of dotted segments through an already-resolved
        # Hash-like value — extracted from `lookup`'s own reduce so
        # `found_of` (the `Find` node's own path projection) can walk a
        # `.find { ... }`-produced element the identical way `lookup`
        # walks a plain attribute path, rather than duplicating the
        # symbol-or-string key step twice in this file. `key?` decides
        # which spelling answers — a bare `||` between the two would
        # treat a genuinely-held `false` the same as an absent key and
        # fall through to the other spelling, landing on `nil`.
        def walk_path(value, segments)
          segments.reduce(value) do |current, segment|
            break nil unless current.respond_to?(:[])

            if current.is_a?(Hash)
              sym = segment.to_sym
              current.key?(sym) ? current[sym] : current[segment]
            else
              begin
                current[segment]
              rescue TypeError
                # M9 (docs/audits/2026-08-10-main-bug-audit.md): a dotted
                # path can walk onto an Array (e.g. the result of `.split`,
                # or a `list_of` attribute) — Array#[] demands an
                # Integer/Range and raises a raw TypeError for a String
                # segment ("no implicit conversion of String into
                # Integer"), which used to cross straight past this
                # sublanguage's own refusal boundary and crash the
                # runtime instead of reading as "this predicate doesn't
                # apply here."
                raise EvaluationError,
                      "cannot read #{segment.inspect} from #{describe(current)}"
              end
            end
          end
        end

        # `field == "literal"` -- vendored addition, not (yet) upstream
        # hecks (migration plan task 8): the third-most pervasive
        # dispatch-time gap this pass found, same family as `.match?`/
        # `.present?` above -- a lookup of a single-field
        # scalar-convenience value object (the exact shape `Value.
        # from_identifier`/`Value::Coercion#fields_for`'s own single-
        # field auto-unwrap already treats as "this VO IS its scalar"
        # everywhere else in this runtime) came back as the `Value`
        # wrapper itself, never unwrapped for READING -- so `Value#==`
        # (which only ever equals another `Value` instance) silently
        # refused every `guarantees "..." do status == "active" end` /
        # `expects "..." do trash_day.present? end`-shaped bare
        # comparison against a raw literal. Confirmed corpus-wide, not
        # one file's mistake: bin-buddy alone has this exact `field ==
        # "literal"` shape in plan.bluebook, service_task.bluebook,
        # route.bluebook, and subscription.bluebook, all equally silent
        # until a real dispatch (never validate) exercised the
        # predicate. Scoped narrowly to the single-field `{value: X}`
        # shape only.
        #
        # UPDATE 2026-08-18: originally scoped to unwrap ONLY the bare
        # (undotted) case, on the belief that a dotted lookup only ever
        # reaches into a VO's OWN field (`field.value`, `field.sub_
        # field`) and so should keep walking `#[]` untouched. That
        # belief held for the single-hop case but not for the general
        # one: a dotted lookup that NAVIGATES THROUGH an entity/list
        # element to a nested field (`leg.voyage`, where `voyage` is
        # itself a single-field VO) landed on the very same unwrapped-
        # `Value` shape the bare case fixed, and hit the identical
        # silent `Value#==` failure -- comparing it against a raw
        # literal or another unwrapped VO returned false for everything,
        # no error. The terminal value of a dotted walk deserves the
        # same "this VO IS its scalar" treatment as a bare lookup's
        # result; only the INTERMEDIATE hops need raw `#[]` addressing
        # to keep navigating. `unwrap_scalar` is idempotent on an
        # already-raw scalar (a String/Integer doesn't respond to
        # `#to_h`), so this is safe for the existing `field.value`-
        # shaped dotted lookups too -- they already returned a raw
        # scalar and are unaffected.
        # UPDATE (single-element value objects strictly answer `.value`):
        # the unwrap used to gate on the sole key being literally NAMED
        # `:value` — correct for the shorthand/closed-set shapes that
        # motivated it, but a lie of omission for `Money{amount}` and
        # every other single-field value object whose author picked a
        # domain name for the field: the SAME "this VO IS its scalar"
        # reading ([[feedback_name_the_scalar_field]], `Behaviour::
        # ValueObject#sole_attribute`) applies regardless of what the
        # sole field happens to be called, and the name gate made a bare
        # `balance > 0` work for a `Balance{value}` while silently
        # comparing a whole VO for a `Balance{amount}`. Now the COUNT is
        # the gate, never the name. A declared `Runtime::Value` reads
        # its own `sole_attribute` (the declaration's answer, not the
        # stored hash's); any OTHER to_h-able (a Struct, a bespoke
        # wrapper with no declaration to consult) keeps the original
        # `{value: X}`-only unwrap, so nothing that never was a value
        # object gains a surprise unwrapping. `rust/src/kernel/json.rs`'s
        # `impl Fielded for Json` mirrors the count-only reading on the
        # Rust side — change them in lockstep or rust_conformance
        # diverges.
        def unwrap_scalar(value)
          return value unless value.respond_to?(:to_h) && !value.is_a?(Hash) && !value.is_a?(Array)

          if value.respond_to?(:value_object)
            sole = value.value_object.sole_attribute
            return sole ? value[sole.name] : value
          end

          hash = value.to_h
          hash.size == 1 && hash.key?(:value) ? hash[:value] : value
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

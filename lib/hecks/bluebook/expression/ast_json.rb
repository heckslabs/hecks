require_relative "evaluator"
require_relative "resolver"

module Hecks
  module Bluebook
    module Expression
      # ── AST → JSON — walks the real Evaluator/Resolver AST (the same
      # objects a live dispatch parses `given`/`ensures`/invariant text
      # into — see docs/implemented/guides/running-a-runtime.md's "The
      # expression grammar") and emits plain, JSON-serializable Ruby
      # Hashes, tagged by `"op"`.
      #
      # ## Relation to `rust/project`'s codegen
      #
      # The same two-method walk `rust/project/expr_emitter.rb`'s own
      # `emit_bool`/`emit_resolver` already do, over the same AST — that
      # file's own methods build Rust source-code strings for `rust/
      # project`'s codegen (`rust/src/kernel::expr::Expr` literals, baked
      # into a generated domain's own compiled binary); this builds data
      # instead, for a genuinely different consumer with a genuinely
      # different constraint: `rust/host` can never link the `rust`
      # (kernel) crate at all (a real, load-bearing build constraint —
      # `reference_validate.rs`'s own header has the full reasoning: one
      # path dependency would statically bake every domain's generated
      # dispatch code into every Lambda binary), so a value object's own
      # `invariant` predicate has to travel as something `rust/host` can
      # deserialize and interpret itself, at runtime, from `ir.json` — the
      # exact same relationship `rust/project`'s own `Expr` literals
      # already have to the compiled kernel, one layer further out.
      #
      # ## Why it lives here
      #
      # Lives in core `lib/hecks`, not `rust/project/` — `rust/project.rb`
      # is a separate, downstream toolchain
      # (`lib/hecks/projector.rb`'s own header: "a whole separate Ruby
      # program"), never `require`d by core `lib/hecks/bluebook/*.rb`
      # files (confirmed: no core file does). `value_object.rb`'s own
      # `invariants:` IR emission needs this for every domain's ordinary
      # `to_h`/`ir.json` export — golden fixtures, `hecks-parse`'s parity
      # comparisons, and any deploy artifact, not only a `bin/project_rust`
      # run — so it belongs beside `Evaluator`/`Resolver` themselves, not
      # bolted onto a tool that only sometimes runs.
      #
      # ## Complete, not corpus-scoped
      #
      # Every node this grammar admits gets a real arm, the identical
      # "raise, don't silently drop" discipline `expr_emitter.rb`'s own
      # `emit_bool`/`emit_resolver` already hold to — even though, as of
      # this writing, no real corpus value object invariant exercises
      # `Include`/`Modulo`/`BlockPredicate`/`Find`/`Array`/`MatchesRegex`/
      # `Presence`/`Assignment`/`Split`/`StartsWith`/`EndsWith`/`First`/
      # `Last` (only `given`/`ensures` clauses do, elsewhere in the corpus
      # — a different consumer of this same grammar).
      # `rust/host/src/expr_json.rs`'s own header names exactly which of
      # these its interpreter evaluates for real today versus refuses
      # cleanly — a narrower, deliberate, documented boundary on the
      # interpreting side, not on this emitting side: an author is free
      # to write any real expression in a value object's own `invariant`,
      # and this always emits it faithfully; whether `rust/host` can yet
      # check it at mint time is that file's own question to answer, not
      # this one's to pre-empt by refusing to even try.
      module AstJson
        module_function

        # **The closed op roster** — every `"op"` tag the walkers below can
        # emit, pinned so a reader (or a spec) can refuse a tag it does
        # not know instead of guessing. A new node kind is a new entry
        # here, a new arm below, and a new arm in every reader.
        OPS = %w[
          or and not compare include
          int float str bool nil array lookup
          add modulo sign_test empty size to_s
          block_predicate find first last
          matches_regex presence assignment split starts_with ends_with
        ].freeze

        # One rule row, the way every rule site emits it — description and
        # canonical text (what every reader has always had) plus the
        # structured form, derived from the same text. `ast` is a pure
        # function of `canonical`: the IR carries both so a reader that
        # only displays keeps the text, and a reader that evaluates never
        # re-parses it.
        #
        # @param rule [Bluebook::Given] the built rule (given/ensures/invariant) to emit
        # @return [Hash{Symbol => Object}] `{description:, canonical:, ast:}`
        def rule_row(rule)
          { description: rule.description, canonical: rule.canonical, ast: rule.ast || emit_predicate(rule.canonical) }
        end

        # Parses and emits a predicate's own canonical text in one step.
        #
        # @param canonical [String] the predicate's own canonical source text
        # @return [Hash{String => Object}] the `"op"`-tagged JSON AST
        def emit_predicate(canonical)
          emit_bool(Evaluator.parse(canonical))
        end

        # C3.6 (docs/semantics/bluebook-semantics.md) — every `.match?`
        # pattern a rule carries is held to `PatternSubset`, exactly as an
        # attribute's own `pattern:` already is (`AttributeCollector#
        # refuse_unshared_pattern`): a regex whose meaning depends on the
        # engine reading it is a defect in the bluebook, refused at build.
        # Walks the emitted AST, so every rule site (givens, ensures,
        # invariants, preconditions, a policy's where) gets the one check.
        #
        # @param ast [Hash{String => Object}] the `"op"`-tagged JSON AST to walk
        # @param owner [String] the construct declaring `ast`, named in a refusal
        # @param word [String] the rule kind, such as `"given"`, named in a refusal
        # @return [Hash{String => Object}] `ast`, unchanged
        # @raise [DSL::Malformed] if any `matches_regex` node's own pattern uses a
        #   construct `PatternSubset` refuses
        def refuse_unshared_patterns!(ast, owner:, word:)
          return ast if Hecks::Bluebook::MetaValidator.shadow_parsing? # frozen era text is history

          each_node(ast) do |node|
            next unless node["op"] == "matches_regex"

            rejection = PatternSubset.validate(node["pattern"])
            next unless rejection

            raise DSL::Malformed,
                  "#{owner}'s #{word} matches against #{node['pattern'].inspect}, which uses a " \
                  "#{rejection.construct} — #{rejection.reason}"
          end
          ast
        end

        # Every name a rule resolves at its root — the first segment of
        # each `lookup` path, unique, in first-seen order.
        #
        # @param ast [Hash{String => Object}] the `"op"`-tagged JSON AST to walk
        # @return [Array<String>] each `lookup` node's own root name, unique, in
        #   first-seen order
        def lookup_heads(ast)
          heads = []
          each_node(ast) do |node|
            heads << node["path"].first.to_s if node["op"] == "lookup" && node["path"].is_a?(::Array)
          end
          heads.uniq
        end

        # Walks every node of an `"op"`-tagged JSON AST, depth first.
        #
        # @param node [Hash{String => Object}, Array, Object] the AST, or a fragment of it
        # @yield [node] one `"op"`-tagged Hash node
        # @yieldparam node [Hash{String => Object}] the node reached
        # @return [void]
        def each_node(node, &block)
          case node
          when ::Hash
            yield node
            node.each_value { |child| each_node(child, &block) }
          when ::Array
            node.each { |child| each_node(child, &block) }
          end
        end

        # Emits one boolean/comparison AST node as `"op"`-tagged JSON.
        #
        # @param node [Object] an `Evaluator` boolean/comparison node — `Or`, `And`,
        #   `Not`, `Compare`, `Include`, or `Resolve`
        # @return [Hash{String => Object}] the `"op"`-tagged JSON for `node`
        # @raise [RuntimeError] if `node` is not one of the handled `Evaluator` classes
        def emit_bool(node)
          case node
          when Evaluator::Or  then { "op" => "or", "left" => emit_bool(node.left), "right" => emit_bool(node.right) }
          when Evaluator::And then { "op" => "and", "left" => emit_bool(node.left), "right" => emit_bool(node.right) }
          when Evaluator::Not then { "op" => "not", "expr" => emit_bool(node.node) }
          when Evaluator::Compare
            { "op" => "compare", "cmp" => emit_comparison(node.operator),
              "left" => emit_resolver(node.left), "right" => emit_resolver(node.right) }
          when Evaluator::Include
            emit_include(node)
          when Evaluator::Resolve
            emit_resolver(node.expr)
          else
            raise "unhandled evaluator node #{node.class} — no JSON rendering exists for it " \
                  "(lib/hecks/bluebook/expression/ast_json.rb#emit_bool)"
          end
        end

        # Emits one comparison operator as its three-flag triple.
        #
        # @param comparator [Evaluator::Operator] the comparison operator to emit
        # @return [Hash{String => Boolean}] `{"less_than"=>, "equal"=>, "negated"=>}`
        def emit_comparison(comparator)
          { "less_than" => comparator.compares_less_than, "equal" => comparator.compares_equal, "negated" => comparator.negated }
        end

        # The JSON-target sibling of `expr_emitter.rb`'s own
        # `emit_include` — see that method's own comment for the full
        # reasoning (a literal array haystack has no `Expr::Include`-
        # representable shape on either target, kernel or host, so both
        # rewrite it identically into an or-of-equalities at emission
        # time rather than carrying a shape neither interpreter could
        # evaluate). A non-literal haystack still emits `include`
        # unchanged.
        EQ = Evaluator::OPERATORS.find { |op| op.symbol == "==" }
        private_constant :EQ

        # Emits an include node, rewriting a literal-array haystack into an or-of-equalities.
        #
        # @param node [Evaluator::Include] the include node to emit
        # @return [Hash{String => Object}] `"include"`-tagged JSON for a non-literal
        #   haystack; an or-of-equalities, or `{"op"=>"bool","value"=>false}` for an
        #   empty one, when the haystack is a literal array
        def emit_include(node)
          return { "op" => "include", "haystack" => emit_resolver(node.haystack), "needle" => emit_resolver(node.needle) } \
            unless node.haystack.is_a?(Resolver::ArrayLiteral)

          return { "op" => "bool", "value" => false } if node.haystack.elements.empty?

          equalities = node.haystack.elements.map do |element|
            { "op" => "compare", "cmp" => emit_comparison(EQ), "left" => emit_resolver(node.needle),
"right" => emit_resolver(element) }
          end
          equalities.reduce { |left, right| { "op" => "or", "left" => left, "right" => right } }
        end

        # One case arm per Resolver node type — the class header above is
        # explicit that this dispatch must stay complete and in one place
        # ("every node this grammar admits gets a real arm"); splitting it
        # into several methods would hide whether the set is still
        # exhaustive instead of making that visible at a glance.
        #
        # @param node [Object] a `Resolver` dotted/arithmetic leaf node
        # @return [Hash{String => Object}] the `"op"`-tagged JSON for `node`
        # @raise [RuntimeError] if `node` is not one of the handled `Resolver` classes
        # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
        def emit_resolver(node)
          case node
          when Resolver::IntegerLiteral then { "op" => "int", "value" => node.value }
          when Resolver::FloatLiteral   then { "op" => "float", "value" => node.value }
          when Resolver::StringLiteral  then { "op" => "str", "value" => node.value }
          when Resolver::BoolLiteral    then { "op" => "bool", "value" => node.value }
          when Resolver::NilLiteral     then { "op" => "nil" }
          # `path` is the same shape `find.path` already has — segments, not
          # a dotted string a reader would have to split by its own rule.
          when Resolver::Lookup         then { "op" => "lookup", "path" => node.path.split(".") }
          when Resolver::Addition       then { "op" => "add", "left" => emit_resolver(node.left), "right" => emit_resolver(node.right) }
          when Resolver::SignTest
            { "op" => "sign_test", "cmp" => emit_comparison(node.operator), "receiver" => emit_resolver(node.receiver) }
          when Resolver::Empty  then { "op" => "empty", "receiver" => emit_resolver(node.receiver) }
          when Resolver::ToS    then { "op" => "to_s", "receiver" => emit_resolver(node.receiver) }
          when Resolver::Modulo then { "op" => "modulo", "receiver" => emit_resolver(node.receiver), "divisor" => emit_resolver(node.divisor) }
          when Resolver::Size   then { "op" => "size", "receiver" => emit_resolver(node.receiver) }
          when Resolver::BlockPredicate
            { "op" => "block_predicate", "mode" => node.mode.to_s, "receiver" => emit_resolver(node.receiver),
              "param" => node.param.to_s, "predicate" => emit_bool(node.predicate) }
          when Resolver::Find
            { "op" => "find", "receiver" => emit_resolver(node.receiver), "param" => node.param.to_s,
              "predicate" => emit_bool(node.predicate), "path" => node.path.map(&:to_s) }
          when Resolver::ArrayLiteral
            { "op" => "array", "elements" => node.elements.map { |element| emit_resolver(element) } }
          when Resolver::MatchesRegex
            { "op" => "matches_regex", "receiver" => emit_resolver(node.receiver), "pattern" => node.pattern,
"flags" => node.flags }
          when Resolver::Presence
            { "op" => "presence", "receiver" => emit_resolver(node.receiver), "negated" => node.negated }
          when Resolver::Assignment
            { "op" => "assignment", "receiver" => emit_resolver(node.receiver), "negated" => node.negated }
          when Resolver::Split
            { "op" => "split", "receiver" => emit_resolver(node.receiver), "separator" => node.separator }
          when Resolver::StartsWith
            { "op" => "starts_with", "receiver" => emit_resolver(node.receiver), "substring" => node.substring }
          when Resolver::EndsWith
            { "op" => "ends_with", "receiver" => emit_resolver(node.receiver), "substring" => node.substring }
          when Resolver::First then { "op" => "first", "receiver" => emit_resolver(node.receiver) }
          when Resolver::Last  then { "op" => "last", "receiver" => emit_resolver(node.receiver) }
          else
            raise "unhandled resolver node #{node.class} — no JSON rendering exists for it " \
                  "(lib/hecks/bluebook/expression/ast_json.rb#emit_resolver)"
          end
        end
      end
    end
  end
end

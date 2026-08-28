require_relative "evaluator"
require_relative "resolver"

module Hecks
  module Bluebook
    module Expression
      # ── AST → JSON — walks the REAL Evaluator/Resolver AST (the same
      # objects a live dispatch parses `given`/`ensures`/invariant text
      # into — see docs/implemented/guides/running-a-runtime.md's "The
      # expression grammar") and emits plain, JSON-serializable Ruby
      # Hashes, tagged by `"op"`.
      #
      # THE SAME TWO-METHOD WALK `rust/project/expr_emitter.rb`'s own
      # `emit_bool`/`emit_resolver` already do, over the SAME AST — that
      # file's own methods build RUST SOURCE-CODE STRINGS for `rust/
      # project`'s codegen (`rust/src/kernel::expr::Expr` literals, baked
      # into a generated domain's own compiled binary); this builds DATA
      # instead, for a genuinely different consumer with a genuinely
      # different constraint: `rust/host` can never link the `rust`
      # (kernel) crate at all (a real, load-bearing build constraint —
      # `reference_validate.rs`'s own header has the full reasoning: one
      # path dependency would statically bake every domain's generated
      # dispatch code into every Lambda binary), so a value object's own
      # `invariant` predicate has to travel as something `rust/host` can
      # deserialize and interpret itself, at RUNTIME, from `ir.json` — the
      # exact same relationship `rust/project`'s own `Expr` literals
      # already have to the compiled kernel, one layer further out.
      #
      # LIVES IN CORE `lib/hecks`, NOT `rust/project/` — `rust/project.rb`
      # is a separate, downstream toolchain
      # (`lib/hecks/projector.rb`'s own header: "a whole separate Ruby
      # program"), never `require`d by core `lib/hecks/bluebook/*.rb`
      # files (confirmed: no core file does). `value_object.rb`'s own
      # `invariants:` IR emission needs this for EVERY domain's ordinary
      # `to_h`/`ir.json` export — golden fixtures, `hecks-parse`'s parity
      # comparisons, and any deploy artifact, not only a `bin/project_rust`
      # run — so it belongs beside `Evaluator`/`Resolver` themselves, not
      # bolted onto a tool that only sometimes runs.
      #
      # COMPLETE, not corpus-scoped: every node this grammar admits gets
      # a real arm, the identical "raise, don't silently drop" discipline
      # `expr_emitter.rb`'s own `emit_bool`/`emit_resolver` already hold
      # to — even though, as of this writing, no real corpus VALUE OBJECT
      # invariant exercises `Include`/`Modulo`/`BlockPredicate`/`Find`/
      # `Array`/`MatchesRegex`/`Presence`/`Assignment`/`Split`/`StartsWith`/
      # `EndsWith`/`First`/`Last` (only `given`/`ensures` clauses do, elsewhere in
      # the corpus — a different consumer of this same grammar).
      # `rust/host/src/expr_json.rs`'s own header names exactly which of
      # these its interpreter evaluates for real today versus refuses
      # cleanly — a narrower, deliberate, documented boundary on the
      # INTERPRETING side, not on this EMITTING side: an author is free
      # to write ANY real expression in a value object's own `invariant`,
      # and this always emits it faithfully; whether `rust/host` can yet
      # CHECK it at mint time is that file's own question to answer, not
      # this one's to pre-empt by refusing to even try.
      module AstJson
        module_function

        def emit_predicate(canonical)
          emit_bool(Evaluator.parse(canonical))
        end

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
            raise "unhandled evaluator node #{node.class} — no JSON rendering exists for it (lib/hecks/bluebook/expression/ast_json.rb#emit_bool)"
          end
        end

        def emit_comparison(op)
          { "less_than" => op.compares_less_than, "equal" => op.compares_equal, "negated" => op.negated }
        end

        # The JSON-target sibling of `expr_emitter.rb`'s own
        # `emit_include` — see that method's own comment for the full
        # reasoning (a LITERAL array haystack has no `Expr::Include`-
        # representable shape on EITHER target, kernel or host, so both
        # rewrite it identically into an OR-of-equalities at emission
        # time rather than carrying a shape neither interpreter could
        # evaluate). A non-literal haystack still emits `include`
        # unchanged.
        EQ = Evaluator::OPERATORS.find { |op| op.symbol == "==" }
        private_constant :EQ

        def emit_include(node)
          return { "op" => "include", "haystack" => emit_resolver(node.haystack), "needle" => emit_resolver(node.needle) } \
            unless node.haystack.is_a?(Resolver::ArrayLiteral)

          return { "op" => "bool", "value" => false } if node.haystack.elements.empty?

          equalities = node.haystack.elements.map do |element|
            { "op" => "compare", "cmp" => emit_comparison(EQ), "left" => emit_resolver(node.needle), "right" => emit_resolver(element) }
          end
          equalities.reduce { |left, right| { "op" => "or", "left" => left, "right" => right } }
        end

        def emit_resolver(node)
          case node
          when Resolver::IntegerLiteral then { "op" => "int", "value" => node.value }
          when Resolver::FloatLiteral   then { "op" => "float", "value" => node.value }
          when Resolver::StringLiteral  then { "op" => "str", "value" => node.value }
          when Resolver::BoolLiteral    then { "op" => "bool", "value" => node.value }
          when Resolver::NilLiteral     then { "op" => "nil" }
          when Resolver::Lookup         then { "op" => "lookup", "path" => node.path }
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
            { "op" => "matches_regex", "receiver" => emit_resolver(node.receiver), "pattern" => node.pattern, "flags" => node.flags }
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
            raise "unhandled resolver node #{node.class} — no JSON rendering exists for it (lib/hecks/bluebook/expression/ast_json.rb#emit_resolver)"
          end
        end
      end
    end
  end
end

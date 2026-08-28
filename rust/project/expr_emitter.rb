module RustProjection
  # ── EXPR EMITTER — walks the REAL Evaluator/Resolver AST (the same
  # objects a live dispatch parses `given`/`ensures`/invariant text into;
  # see docs/implemented/guides/running-a-runtime.md's "The expression grammar") and
  # emits Rust `Expr` DATA LITERAL source — not a compiled boolean
  # expression. Every real node kind maps directly; there is no
  # `Unsupported` case, because a runtime interpreter (unlike a static
  # compiler) needs no int/float unification or fixed receiver — see
  # rust/src/kernel/expr.rs's own header for why.
  module ExprEmitter
    module_function

    def emit_predicate(canonical)
      emit_bool(Hecks::Bluebook::Expression::Evaluator.parse(canonical))
    end

    def emit_bool(node)
      ev = Hecks::Bluebook::Expression::Evaluator
      case node
      when ev::Or  then "Expr::Or(Box::new(#{emit_bool(node.left)}), Box::new(#{emit_bool(node.right)}))"
      when ev::And then "Expr::And(Box::new(#{emit_bool(node.left)}), Box::new(#{emit_bool(node.right)}))"
      when ev::Not then "Expr::Not(Box::new(#{emit_bool(node.node)}))"
      when ev::Compare
        "Expr::Compare { op: #{emit_comparison(node.operator)}, left: Box::new(#{emit_resolver(node.left)}), right: Box::new(#{emit_resolver(node.right)}) }"
      when ev::Include
        emit_include(node)
      when ev::Resolve
        emit_resolver(node.expr)
      else
        # NAME THE OPERATOR, DON'T ACCUSE THE GRAMMAR. Used to say "the
        # real grammar has no such node" unconditionally — true only for
        # a node type this file has genuinely never heard of (a real
        # emitter bug). It was FALSE the day the resolver vendored eight
        # operators (`.match?`/`.present?`/`.blank?`/`.split`/
        # `.start_with?`/`.end_with?`/`.first`/`.last`) straight into
        # `resolver.rb` without a matching `emit_resolver` arm here — the
        # grammar had exactly such a node, admitted and running in Ruby,
        # and this message told whoever hit it to look in the wrong
        # place. Every node type this generator has NO arm for at all is
        # still a real bug (this `else` firing on an `ev::` node should
        # never happen, `Evaluator.parse` has no eighth node kind), so
        # this stays a hard failure — it just stops lying about which
        # file is stale.
        raise "unhandled evaluator node #{node.class} — no Rust rendering exists for it in this generator (rust/project/expr_emitter.rb#emit_bool)"
      end
    end

    # Fully qualified, not `use`d bare — the self-hosted grammar's own
    # Vocabulary chapter declares ITS OWN "Comparison" (a multi-field closed
    # set describing the six real operators, emitted as a struct + static
    # array — see emit_closed_set_table), a completely different Rust type
    # that happens to share this hand-written kernel struct's name. Bare
    # `Comparison { .. }` would collide the moment a generated file needs
    # both; qualifying here means it never can, regardless of what any
    # target domain happens to call things.
    def emit_comparison(op)
      "crate::kernel::Comparison { less_than: #{op.compares_less_than}, equal: #{op.compares_equal}, negated: #{op.negated} }"
    end

    # `Expr::Include { haystack, needle }` exists in the kernel for a REAL
    # list-typed FIELD haystack (`Value::List` there is a length, per that
    # file's own header — a list field only ever answers `.size`/
    # `.empty?`, never membership by value) — it was never built to check
    # membership against a literal SET of scalars, and nothing in the
    # corpus asks it to.
    #
    # `["issued", "active"].include?(status)` is different: haystack is a
    # LITERAL `ArrayLiteral`, every element already known at generation
    # time. Rather than growing the kernel a second `Value` shape (a real
    # `Vec<Value>` alongside the length-only `List`) for a haystack that
    # is always fully known before a single record is ever read, this
    # rewrites it into what it always meant — `needle == "issued" ||
    # needle == "active"` — using the SAME `Expr::Compare`/`Expr::Or` every
    # other equality/either-or check in this grammar already compiles to.
    # `Evaluator#includes?`'s own `Array` branch (`found.any? { |item|
    # equal?(item, wanted) }`) is exactly an OR of equalities; this is
    # that fact, generated instead of interpreted.
    #
    # A non-literal haystack (a real list-typed field, or a String) still
    # emits `Expr::Include` unchanged — this only rewrites the shape the
    # kernel cannot represent.
    EQ = Hecks::Bluebook::Expression::Evaluator::OPERATORS.find { |op| op.symbol == "==" }
    private_constant :EQ

    def emit_include(node)
      r = Hecks::Bluebook::Expression::Resolver
      return "Expr::Include { haystack: Box::new(#{emit_resolver(node.haystack)}), needle: Box::new(#{emit_resolver(node.needle)}) }" \
        unless node.haystack.is_a?(r::ArrayLiteral)

      return "Expr::Bool(false)" if node.haystack.elements.empty?

      node.haystack.elements
          .map { |element| "Expr::Compare { op: #{emit_comparison(EQ)}, left: Box::new(#{emit_resolver(node.needle)}), right: Box::new(#{emit_resolver(element)}) }" }
          .reduce { |left, right| "Expr::Or(Box::new(#{left}), Box::new(#{right}))" }
    end

    def emit_resolver(node)
      r = Hecks::Bluebook::Expression::Resolver
      case node
      when r::IntegerLiteral then "Expr::Int(#{node.value})"
      when r::FloatLiteral   then "Expr::Float(#{node.value}f64)"
      when r::StringLiteral  then "Expr::Str(#{node.value.inspect}.to_string())"
      when r::BoolLiteral    then "Expr::Bool(#{node.value})"
      when r::NilLiteral     then "Expr::Nil"
      when r::Lookup         then "Expr::Lookup(#{node.path.inspect})"
      when r::Addition       then "Expr::Add(Box::new(#{emit_resolver(node.left)}), Box::new(#{emit_resolver(node.right)}))"
      when r::SignTest
        "Expr::SignTest { op: #{emit_comparison(node.operator)}, receiver: Box::new(#{emit_resolver(node.receiver)}) }"
      when r::Empty  then "Expr::Empty(Box::new(#{emit_resolver(node.receiver)}))"
      when r::ToS    then "Expr::ToS(Box::new(#{emit_resolver(node.receiver)}))"
      when r::Modulo then "Expr::Modulo { receiver: Box::new(#{emit_resolver(node.receiver)}), divisor: Box::new(#{emit_resolver(node.divisor)}) }"
      when r::Size   then "Expr::Size(Box::new(#{emit_resolver(node.receiver)}))"
      when r::BlockPredicate
        "Expr::BlockPredicate { mode: crate::kernel::BlockMode::#{node.mode.to_s.capitalize}, receiver: Box::new(#{emit_resolver(node.receiver)}), " \
          "param: #{node.param.inspect}, predicate: Box::new(#{emit_bool(node.predicate)}) }"
      when r::Find
        "Expr::Find { receiver: Box::new(#{emit_resolver(node.receiver)}), param: #{node.param.inspect}, " \
          "predicate: Box::new(#{emit_bool(node.predicate)}), path: &[#{node.path.map(&:inspect).join(', ')}] }"
      when r::ArrayLiteral
        "Expr::Array(vec![#{node.elements.map { |element| emit_resolver(element) }.join(', ')}])"
      when r::MatchesRegex
        "Expr::MatchesRegex { receiver: Box::new(#{emit_resolver(node.receiver)}), pattern: #{node.pattern.inspect}.to_string(), flags: #{node.flags.inspect}.to_string() }"
      when r::Presence
        "Expr::Presence { receiver: Box::new(#{emit_resolver(node.receiver)}), negated: #{node.negated} }"
      when r::Split
        "Expr::Split { receiver: Box::new(#{emit_resolver(node.receiver)}), separator: #{node.separator.inspect}.to_string() }"
      when r::StartsWith
        "Expr::StartsWith { receiver: Box::new(#{emit_resolver(node.receiver)}), substring: #{node.substring.inspect}.to_string() }"
      when r::EndsWith
        "Expr::EndsWith { receiver: Box::new(#{emit_resolver(node.receiver)}), substring: #{node.substring.inspect}.to_string() }"
      when r::First then "Expr::First(Box::new(#{emit_resolver(node.receiver)}))"
      when r::Last  then "Expr::Last(Box::new(#{emit_resolver(node.receiver)}))"
      else
        # See `emit_bool`'s own `else` arm for why this no longer blames
        # the grammar unconditionally — the identical fix, mirrored here
        # for the resolver's own leaf grammar.
        raise "unhandled resolver node #{node.class} — no Rust rendering exists for it in this generator (rust/project/expr_emitter.rb#emit_resolver)"
      end
    end
  end
end

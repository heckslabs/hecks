module Hecksagain
  module Rust
    # ── EXPR EMITTER — walks the REAL Evaluator/Resolver AST (the same
    # objects a live dispatch parses `given`/`ensures`/invariant text into;
    # see docs/guides/writing-a-port.md's "The expression grammar") and
    # emits Rust `Expr` DATA LITERAL source — not a compiled boolean
    # expression. Every real node kind maps directly; there is no
    # `Unsupported` case, because a runtime interpreter (unlike a static
    # compiler) needs no int/float unification or fixed receiver — see
    # rust_runner/src/kernel/expr.rs's own header for why.
    module ExprEmitter
      module_function

      def emit_predicate(canonical)
        emit_bool(Hecksagain::Bluebook::Expression::Evaluator.parse(canonical))
      end

      def emit_bool(node)
        ev = Hecksagain::Bluebook::Expression::Evaluator
        case node
        when ev::Or  then "Expr::Or(Box::new(#{emit_bool(node.left)}), Box::new(#{emit_bool(node.right)}))"
        when ev::And then "Expr::And(Box::new(#{emit_bool(node.left)}), Box::new(#{emit_bool(node.right)}))"
        when ev::Not then "Expr::Not(Box::new(#{emit_bool(node.node)}))"
        when ev::Compare
          "Expr::Compare { op: #{emit_comparison(node.operator)}, left: Box::new(#{emit_resolver(node.left)}), right: Box::new(#{emit_resolver(node.right)}) }"
        when ev::Include
          "Expr::Include { haystack: Box::new(#{emit_resolver(node.haystack)}), needle: Box::new(#{emit_resolver(node.needle)}) }"
        when ev::Resolve
          emit_resolver(node.expr)
        else
          raise "unhandled evaluator node #{node.class} — the real grammar has no such node; this generator is stale"
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

      def emit_resolver(node)
        r = Hecksagain::Bluebook::Expression::Resolver
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
        else
          raise "unhandled resolver node #{node.class} — the real grammar has no such node; this generator is stale"
        end
      end
    end
  end
end

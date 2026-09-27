module RustProjection
  # Emits Rust `Expr` data-literal source from the `ast` tree of an IR rule row.
  # Mirrors rust/codegen/src/expr_emitter.rs node for node; see `AstJson::OPS`.
  # `include` arm below only ever sees a real field/string haystack.
  module ExprEmitter
    module_function

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    def emit_ast(node)
      case at(node, :op)
      when "or"  then "Expr::Or(Box::new(#{emit_ast(at(node, :left))}), Box::new(#{emit_ast(at(node, :right))}))"
      when "and" then "Expr::And(Box::new(#{emit_ast(at(node, :left))}), Box::new(#{emit_ast(at(node, :right))}))"
      when "not" then "Expr::Not(Box::new(#{emit_ast(at(node, :expr))}))"
      when "compare"
        "Expr::Compare { op: #{emit_comparison(at(node, :cmp))}, left: Box::new(#{emit_ast(at(node, :left))}), right: Box::new(#{emit_ast(at(node, :right))}) }"
      when "include"
        "Expr::Include { haystack: Box::new(#{emit_ast(at(node, :haystack))}), needle: Box::new(#{emit_ast(at(node, :needle))}) }"
      when "int"    then "Expr::Int(#{at(node, :value)})"
      when "float"  then "Expr::Float(#{at(node, :value)}f64)"
      when "str"    then "Expr::Str(#{at(node, :value).inspect}.to_string())"
      when "bool"   then "Expr::Bool(#{at(node, :value)})"
      when "nil"    then "Expr::Nil"
      when "lookup" then "Expr::Lookup(#{at(node, :path).join('.').inspect})"
      when "add"    then "Expr::Add(Box::new(#{emit_ast(at(node, :left))}), Box::new(#{emit_ast(at(node, :right))}))"
      when "sign_test"
        "Expr::SignTest { op: #{emit_comparison(at(node, :cmp))}, receiver: Box::new(#{emit_ast(at(node, :receiver))}) }"
      when "empty"  then "Expr::Empty(Box::new(#{emit_ast(at(node, :receiver))}))"
      when "to_s"   then "Expr::ToS(Box::new(#{emit_ast(at(node, :receiver))}))"
      when "modulo"
        "Expr::Modulo { receiver: Box::new(#{emit_ast(at(node, :receiver))}), divisor: Box::new(#{emit_ast(at(node, :divisor))}) }"
      when "size"   then "Expr::Size(Box::new(#{emit_ast(at(node, :receiver))}))"
      when "block_predicate"
        "Expr::BlockPredicate { mode: crate::kernel::BlockMode::#{at(node, :mode).capitalize}, receiver: Box::new(#{emit_ast(at(node, :receiver))}), " \
          "param: #{at(node, :param).inspect}, predicate: Box::new(#{emit_ast(at(node, :predicate))}) }"
      when "find"
        "Expr::Find { receiver: Box::new(#{emit_ast(at(node, :receiver))}), param: #{at(node, :param).inspect}, " \
          "predicate: Box::new(#{emit_ast(at(node, :predicate))}), path: &[#{at(node, :path).map(&:inspect).join(', ')}] }"
      when "array"
        "Expr::Array(vec![#{at(node, :elements).map { |element| emit_ast(element) }.join(', ')}])"
      when "matches_regex"
        "Expr::MatchesRegex { receiver: Box::new(#{emit_ast(at(node, :receiver))}), pattern: #{at(node, :pattern).inspect}.to_string(), flags: #{at(node, :flags).inspect}.to_string() }"
      when "presence"
        "Expr::Presence { receiver: Box::new(#{emit_ast(at(node, :receiver))}), negated: #{at(node, :negated)} }"
      when "assignment"
        "Expr::Assignment { receiver: Box::new(#{emit_ast(at(node, :receiver))}), negated: #{at(node, :negated)} }"
      when "split"
        "Expr::Split { receiver: Box::new(#{emit_ast(at(node, :receiver))}), separator: #{at(node, :separator).inspect}.to_string() }"
      when "starts_with"
        "Expr::StartsWith { receiver: Box::new(#{emit_ast(at(node, :receiver))}), substring: #{at(node, :substring).inspect}.to_string() }"
      when "ends_with"
        "Expr::EndsWith { receiver: Box::new(#{emit_ast(at(node, :receiver))}), substring: #{at(node, :substring).inspect}.to_string() }"
      when "first" then "Expr::First(Box::new(#{emit_ast(at(node, :receiver))}))"
      when "last"  then "Expr::Last(Box::new(#{emit_ast(at(node, :receiver))}))"
      else
        # An op with no arm above means `AstJson::OPS` grew and this file did not.
        raise "unhandled ast op #{at(node, :op).inspect} — no Rust rendering exists for it in this generator (rust/project/expr_emitter.rb#emit_ast)"
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

    # Fully qualified: the grammar's own "Comparison" closed set would collide with the
    # kernel struct of the same name in a file that needs both.
    def emit_comparison(cmp)
      "crate::kernel::Comparison { less_than: #{at(cmp, :less_than)}, equal: #{at(cmp, :equal)}, negated: #{at(cmp, :negated)} }"
    end

    # Reads a key from a symbol-keyed (round-tripped) or string-keyed (`AstJson`) node.
    def at(node, key)
      node.key?(key) ? node[key] : node.fetch(key.to_s)
    end
  end
end

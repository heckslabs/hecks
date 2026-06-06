# Hecks::Behaviors::CrossAggregateGate
#
# Slice-1 cross-aggregate POINT gate pre-resolution — the Ruby mirror of the
# Rust command_dispatch resolver. A `given` may read ONE named sibling's field
# as `Agg(id_expr).field` (e.g. `Folder(folder).status == "approved"`). We
# resolve each such term BEFORE check_givens and inject the value into attrs
# under the literal term, so the pure Interpreter resolves it via its existing
# attrs fallback. The aggregate-consistency boundary holds : the command still
# writes ONE aggregate ; this is a READ at the gate (the port), never a cross
# write.
#
#   CrossAggregateGate.resolve(runtime, cmd, state, attrs)
module Hecks
  module Behaviors
    module CrossAggregateGate
      module_function

      # `runtime` must respond to `find(aggregate_name, id)` (returns an
      # AggregateState or nil). Mutates `attrs` in place.
      def resolve(runtime, cmd, state, attrs)
        (cmd.givens || []).each do |given|
          extract_terms(given.expression.to_s).each do |term|
            next if attrs.key?(term[:full])
            # Set-gate : `Agg(list_field).unresolved` -- the SET generalisation
            # of the point gate below, quantified over a self ref-LIST. The
            # reserved `unresolved` projection marks a quantified read : `id_expr`
            # names a ref-list, we resolve EACH referenced sibling and inject the
            # ids that are NOT yet resolved (state neither "done" nor "cancelled"
            # ; a missing sibling counts as unresolved -- fail closed) as a
            # Value.list under the literal term. Mirror of the Rust resolver ;
            # the interpreter `.unresolved.empty?` reads it via `.size`.
            if term[:field] == "unresolved"
              src = attrs[term[:id_expr]] || attrs[term[:id_expr].to_sym] ||
                    (state && state.get(term[:id_expr]))
              listv = src.is_a?(Value) ? src : Value.from(src)
              dep_ids = listv.list? ? listv.raw.map { |v| v.to_display.to_s } : []
              unresolved = dep_ids.reject do |id|
                sib = runtime.find(term[:aggregate], id)
                sib && %w[done cancelled].include?(sib.get("state").to_display.to_s)
              end
              attrs[term[:full]] = Value.list(unresolved)
              next
            end
            raw = attrs[term[:id_expr]] || attrs[term[:id_expr].to_sym] ||
                  (state && state.get(term[:id_expr]))
            # Value#to_s is the object inspect form ; to_display is the raw
            # scalar (mirror of Rust Value::to_string). Without this the id is
            # garbage and the sibling lookup misses — caught by the parity fixture.
            sibling_id = raw.respond_to?(:to_display) ? raw.to_display.to_s : raw.to_s
            next if sibling_id.nil? || sibling_id.empty?
            sibling = runtime.find(term[:aggregate], sibling_id)
            next unless sibling
            # Inject the Value object ; the interpreter resolves it directly
            # (parity with Rust, which clones the sibling Value into attrs).
            attrs[term[:full]] = sibling.get(term[:field])
          end
        end
      end

      # Every `Aggregate(id_expr).field` term in an expression. `Aggregate` is
      # UpperCamelCase immediately followed by `(` ; `id_expr` is the bare token
      # inside the parens ; `field` is the single dotted suffix. The matched
      # substring IS the injection key — mirror of Rust extract_xref_terms.
      def extract_terms(expr)
        terms = []
        expr.scan(/[A-Z][A-Za-z0-9]*\([^)]+\)\.[A-Za-z0-9_]+/) do |full|
          m = full.match(/\A([A-Z][A-Za-z0-9]*)\(([^)]+)\)\.([A-Za-z0-9_]+)\z/)
          terms << { aggregate: m[1], id_expr: m[2].strip, field: m[3], full: full }
        end
        terms
      end
    end
  end
end

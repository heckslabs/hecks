# [antibody-exempt: parity/canonical_ir.rb — kernel-floor canonical IR dump,
#  Phase 2.c set_specs key mirrors rust/src/dump.rs.]
#
# Hecks::Parity::CanonicalIR
#
# Walks a Hecks::BluebookModel::Structure::Domain and emits canonical JSON
# matching the shape that storehouse dump produces. This is the parity
# contract — both parsers must produce equivalent JSON for the same .bluebook.
#
# When the JSONs disagree, that is drift.
#
# The canonical shape is documented in storehouse/src/dump.rs. Field naming
# is normalized: Ruby's Reference#type → "target", Attribute#type → "type"
# (string), Lifecycle transitions Hash → ordered Vec of {command,
# to_state, from_state}, Fixture attributes Hash → ordered [[k, v], ...].
#
# Policies are flattened: Ruby holds them on Aggregate AND Domain; canonical
# JSON puts them all under top-level "policies" (matching Rust).
#
# Usage:
#   require "hecks"
#   require_relative "canonical_ir"
#   domain = Hecks.last_domain  # after loading a .bluebook
#   json = Hecks::Parity::CanonicalIR.dump(domain)
#   puts JSON.pretty_generate(json)
#
require "json"

module Hecks
  module Parity
    module CanonicalIR
      module_function

      def dump(domain)
        all_policies = collect_all_policies(domain)
        pms = domain.respond_to?(:process_managers) ? (domain.process_managers || []) : []
        {
          "name"             => domain.name,
          "category"         => category_for(domain),
          "vision"           => domain.vision,
          "aggregates"       => domain.aggregates.map { |a| dump_aggregate(a) },
          "policies"         => all_policies.map { |p| dump_policy(p) },
          "fixtures"         => (domain.fixtures || []).map { |f| dump_fixture(f) },
          "process_managers" => pms.map { |pm| dump_process_manager(pm) },
        }
      end

      # Mirror Rust's dump_process_manager. Static shape only — the action
      # proc on each handler is intentionally NOT dumped (Ruby-side
      # execution, not part of the parity contract).
      def dump_process_manager(pm)
        {
          "name"          => pm.name.to_s,
          "correlates_by" => pm.correlates_by.to_s,
          "starts_on"     => pm.starts_on.to_s,
          "ends_on"       => pm.ends_on.nil? ? nil : pm.ends_on.to_s,
          "states"        => (pm.states || []).map(&:to_s),
          "handlers"      => (pm.handlers || []).map { |h| dump_pm_handler(h) },
        }
      end

      def dump_pm_handler(h)
        from, to = h.transition.first
        # Phase 2.c — `set_specs` carries the declarative
        # `set :attr, value_spec` list captured from the on-block.
        # Each entry serialises as a [attr_name, value_spec] pair so
        # declaration order survives JSON round-trip (matches Rust's
        # Vec<(String, ValueSpec)> shape exactly).
        set_specs = (h.respond_to?(:set_specs) ? (h.set_specs || []) : [])
        {
          # `dispatches` carries the declarative Aggregate.Command list
          # captured from `dispatch "..."` keyword inside the on-block.
          # Empty when the handler used the Ruby-proc form. Each entry
          # is a structured DispatchSpec carrying the command name and
          # an ordered with-spec : Phase 2.b (pm-dispatch-enrichment)
          # extends bare strings with attribute flow (literal /
          # from_event / from_pm).
          "dispatches" => (h.respond_to?(:dispatches) ? (h.dispatches || []) : []).map { |d| dump_dispatch(d) },
          "event_type" => h.event_type.to_s,
          "from_state" => from.to_s,
          "set_specs"  => set_specs.map { |attr, spec| [attr.to_s, dump_value_spec(spec)] },
          "to_state"   => to.to_s,
        }
      end

      # Mirror Rust's dump_dispatch. Accepts both the new DispatchSpec
      # struct (Phase 2.b+) and bare strings (legacy ; future-proof if
      # hand-built IRs in tests still pass strings). Strings normalise
      # to a DispatchSpec with empty +with_spec+ and +for_each = nil+.
      #
      # i221-A — emits +"for_each"+ key on every DispatchSpec. The
      # value is a +{source_aggregate, query_name}+ object when the
      # dispatch declared a sweep, +nil+ (JSON null) otherwise. Bare
      # / single-record dispatches stay byte-identical to the prior
      # shape because the only addition is a new key whose value
      # serialises as +null+.
      def dump_dispatch(d)
        if d.is_a?(String)
          { "command_name" => d, "for_each" => nil, "with" => [] }
        else
          {
            "command_name" => d.command_name.to_s,
            "for_each"     => dump_for_each_spec(d.respond_to?(:for_each_spec) ? d.for_each_spec : nil),
            "with"         => (d.with_spec || []).map { |key, spec| [key.to_s, dump_value_spec(spec)] },
          }
        end
      end

      # i221-A — mirror Rust's dump_for_each. +nil+ → JSON null ;
      # otherwise emit a fixed-key object with +source_aggregate+ and
      # +query_name+. Both fields stringified through +to_s+ so the
      # canonical shape is unambiguous.
      def dump_for_each_spec(spec)
        return nil if spec.nil?
        ctx = spec.respond_to?(:source_context) ? spec.source_context : nil
        qi = spec.respond_to?(:query_inputs) ? (spec.query_inputs || []) : []
        {
          "source_context"   => ctx.nil? ? nil : ctx.to_s,
          "source_aggregate" => spec.source_aggregate.to_s,
          "query_name"       => spec.query_name.to_s,
          "query_inputs"     => qi.map { |key, vspec| [key.to_s, dump_value_spec(vspec)] },
        }
      end

      # Mirror Rust's dump_value_spec. Four kinds : literal, from_event,
      # from_pm, from_iter (i221-A). Literals stringify their +value+
      # through to_s ; future work may type-tag this when
      # dispatch_cascade learns numeric passing. +default+ is dumped
      # as-is (nil → JSON null).
      def dump_value_spec(spec)
        case spec.kind.to_sym
        when :literal
          { "kind" => "literal", "value" => stringify_literal(spec.value) }
        when :from_event
          { "kind" => "from_event", "name" => spec.name.to_s,
            "default" => stringify_literal(spec.default) }
        when :from_pm
          { "kind" => "from_pm", "name" => spec.name.to_s,
            "default" => stringify_literal(spec.default) }
        when :from_iter
          { "kind" => "from_iter", "field" => spec.name.to_s }
        else
          raise "unknown ValueSpec.kind=#{spec.kind.inspect}"
        end
      end

      # Literals + defaults arrive as Ruby scalars in the DSL ; Rust
      # captures them as Strings (parser layer is line-textual). Coerce
      # to String for byte-identical canonical JSON. nil → nil (JSON
      # null), else to_s.
      def stringify_literal(v)
        return nil if v.nil?
        v.to_s
      end

      def dump_aggregate(agg)
        {
          "name"          => agg.name,
          "context"       => agg.respond_to?(:context) ? agg.context : nil,
          "description"   => agg.description,
          "attributes"    => (agg.attributes || []).map { |a| dump_attribute(a) },
          "value_objects" => (agg.value_objects || []).map { |vo| dump_value_object(vo) },
          "entities"      => (agg.entities || []).map { |ent| dump_entity(ent) },
          "references"    => (agg.references || []).map { |r| dump_reference(r) },
          # First-class factories (2026-06-12) — births, BEFORE commands,
          # mirroring dump.rs's `factories: Vec<Factory>` at the same slot.
          "factories"     => (agg.respond_to?(:factories) ? (agg.factories || []) : []).map { |f| dump_factory(f) },
          "commands"      => (agg.commands || []).map { |c| dump_command(c) },
          "queries"       => (agg.queries || []).map { |q| dump_query(q) },
          "lifecycle"     => agg.lifecycle && dump_lifecycle(agg.lifecycle),
          # f4 — aggregate-level invariants. Mirrors dump.rs's
          # `invariants: Vec<Invariant>` projection. Each Invariant
          # serialises as { name, expression } in declaration order so the
          # canonical JSON round-trips byte-identically with the Rust dumper.
          # Only the f4 `holds_when { ... }` form carries a machine predicate ;
          # the Rust parser captures ONLY that form (legacy doc-only
          # `invariant("msg") do ... end` blocks have no single-line
          # predicate and parse to nothing), so the Ruby side filters to
          # invariants with a captured expression to stay byte-identical.
          "invariants"    => (agg.respond_to?(:invariants) ? (agg.invariants || []) : [])
                               .select { |inv| inv.respond_to?(:expression) && !inv.expression.nil? }
                               .map { |inv| dump_invariant(inv) },
          # i254 — views per role. Mirrors dump.rs's
          # `views: Vec<View>` projection. Each View serialises as
          # { name, show_all, fields: [str, ...] } ; declaration order
          # is preserved so the canonical JSON round-trips
          # byte-identically with the Rust dumper.
          "views"         => (agg.respond_to?(:views) ? (agg.views || []) : []).map { |v| dump_view(v) },
        }
      end

      # Mirror Rust's dump_view (i254). View has three fields :
      # name (String), show_all (bool), fields (Vec<String>). Symbols
      # in the Ruby side stringify through to_s so the canonical shape
      # matches the Rust JSON byte-for-byte.
      def dump_view(v)
        {
          "name"     => v.name.to_s,
          "show_all" => !!v.show_all,
          "fields"   => (v.fields || []).map(&:to_s),
        }
      end

      def dump_entity(ent)
        # i111-J — entities can declare commands, queries, lifecycle,
        # and identified_by the same way aggregates do. Mirror dump.rs
        # so both parsers emit byte-equal canonical IR for entities
        # carrying behavior.
        {
          "name"          => ent.name,
          "description"   => ent.respond_to?(:description) ? ent.description : nil,
          "identified_by" => ent.respond_to?(:identified_by) && ent.identified_by ? ent.identified_by.to_s : nil,
          "attributes"    => (ent.attributes || []).map { |a| dump_attribute(a) },
          "commands"      => (ent.respond_to?(:commands) ? (ent.commands || []) : []).map { |c| dump_command(c) },
          "queries"       => (ent.respond_to?(:queries)  ? (ent.queries  || []) : []).map { |q| dump_query(q) },
          "lifecycle"     => (ent.respond_to?(:lifecycle) && ent.lifecycle) ? dump_lifecycle(ent.lifecycle) : nil,
        }
      end

      def dump_attribute(attr)
        {
          "name"    => attr.name.to_s,
          "type"    => type_string(attr.type),
          "list"    => attr.list?,
          "default" => attr.default.nil? ? nil : attr.default.to_s,
        }
      end

      def dump_value_object(vo)
        {
          "name"        => vo.name,
          "description" => vo.description,
          "attributes"  => (vo.attributes || []).map { |a| dump_attribute(a) },
        }
      end

      def dump_reference(ref)
        # Mirrors Rust's dump_reference exactly : name, target, domain, kind,
        # cardinality (in that order ; the parity contract is string-diffed so
        # key order matters).
        card = ref.respond_to?(:cardinality) && ref.cardinality ? ref.cardinality : { min: 0, max: 1 }
        kind = ref.respond_to?(:kind) && ref.kind ? ref.kind.to_s : "reference_to"
        {
          "name"        => ref.name.to_s,
          "target"      => ref.type, # Ruby calls it `type`, canonical is `target`
          "domain"      => ref.domain,
          "kind"        => kind,
          "cardinality" => {
            "min" => card[:min],
            "max" => card[:max],
          },
        }
      end

      def dump_command(cmd)
        {
          "name"                 => cmd.name,
          "description"          => command_description(cmd),
          "role"                 => primary_role(cmd),
          "emits"                => emit_string(cmd.emits),
          # i250 — events have identity. `emits "X", identified_by: :y`
          # carries the event-identity attribute name. Same word
          # aggregates use for primary keys ; reused on the emit side
          # to dedupe two reports of the same event.
          "emits_identified_by"  => (cmd.respond_to?(:emits_identified_by) ? cmd.emits_identified_by : nil),
          "attributes"           => (cmd.attributes || []).map { |a| dump_attribute(a) },
          "references"           => (cmd.references || []).map { |r| dump_reference(r) },
          "givens"               => (cmd.respond_to?(:givens) && cmd.givens || []).map { |g| dump_given(g) },
          "mutations"            => (cmd.respond_to?(:mutations) && cmd.mutations || []).map { |m| dump_mutation(m) },
        }
      end

      # First-class factories (2026-06-12) — a birth's canonical IR.
      # Field order mirrors dump.rs's dump_factory exactly : produces sits
      # in the role-adjacent slot. `produces` nil = births the enclosing
      # aggregate ; a name = the cross-aggregate case (Backlog drafts Story).
      def dump_factory(fac)
        {
          "name"                 => fac.name,
          "description"          => command_description(fac),
          "role"                 => primary_role(fac),
          "produces"             => (fac.respond_to?(:produces) ? fac.produces : nil),
          "emits"                => emit_string(fac.emits),
          "emits_identified_by"  => (fac.respond_to?(:emits_identified_by) ? fac.emits_identified_by : nil),
          "attributes"           => (fac.attributes || []).map { |a| dump_attribute(a) },
          "references"           => (fac.references || []).map { |r| dump_reference(r) },
          "givens"               => (fac.respond_to?(:givens) && fac.givens || []).map { |g| dump_given(g) },
          "mutations"            => (fac.respond_to?(:mutations) && fac.mutations || []).map { |m| dump_mutation(m) },
        }
      end

      def dump_query(q)
        {
          "name"        => q.name.to_s,
          "description" => q.respond_to?(:description) ? q.description : nil,
          "attributes"  => (q.respond_to?(:attributes) && q.attributes || []).map { |a| dump_attribute(a) },
          "wheres"      => (q.respond_to?(:wheres) && q.wheres || []).map { |w| dump_where_clause(w) },
          "order_by"    => (q.respond_to?(:order_by) && q.order_by) ? dump_order_by(q.order_by) : nil,
          "limit"       => (q.respond_to?(:limit) && q.limit) ? dump_limit_spec(q.limit) : nil,
        }
      end

      # i101 — structured query clauses. Mirror Rust's dump.rs shape :
      # WhereClause { field, op, value } / OrderBy { field, direction } /
      # LimitSpec { value }. Op + Direction render as lowercase strings
      # to match Rust's enum_match emitters.
      def dump_where_clause(w)
        {
          "field" => w.field.to_s,
          "op"    => w.op.to_s,
          "value" => w.value.to_s,
        }
      end

      def dump_order_by(o)
        {
          "field"     => o.field.to_s,
          "direction" => o.direction.to_s,
        }
      end

      def dump_limit_spec(l)
        {
          "value" => l.value.to_s,
        }
      end

      def dump_given(g)
        {
          "expression" => g.respond_to?(:expression) ? g.expression : g.to_s,
          "message"    => g.respond_to?(:message) ? g.message : nil,
        }
      end

      # f4 — mirror Rust's dump_invariant. Invariant has two canonical
      # fields : name (the rule identifier / message) and expression (the
      # `holds_when { ... }` predicate source). Both stringify so the shape
      # matches the Rust JSON byte-for-byte.
      def dump_invariant(inv)
        {
          "name"       => inv.respond_to?(:message) ? inv.message.to_s : inv.to_s,
          "expression" => (inv.respond_to?(:expression) ? inv.expression : nil).to_s,
        }
      end

      def dump_mutation(m)
        {
          "field" => m.field.to_s,
          "op"    => mutation_op(m),
          "value" => normalize_value(mutation_value(m.value).to_s),
        }
      end

      # Preserve source-text representation for mutation values. Rust keeps
      # the original source bytes ("alert" stays \"alert\", :alert stays
      # :alert, { k: v } stays { k: v }). Ruby parsed these into native
      # objects, so we reverse-format them back to the same canonical text.
      def mutation_value(v)
        case v
        when Symbol then ":#{v}"
        when String then "\"#{v}\""
        when Numeric, TrueClass, FalseClass then v.to_s
        when nil then nil
        when Hash  then "{ #{v.map { |k, val| "#{k}: #{mutation_value(val)}" }.join(', ')} }"
        when Array then "[#{v.map { |e| mutation_value(e) }.join(', ')}]"
        else v.to_s
        end
      end

      def mutation_op(m)
        return m.operation.to_s.downcase if m.respond_to?(:operation)
        "set"
      end

      def dump_lifecycle(lc)
        {
          "field"       => lc.field.to_s,
          "default"     => lc.default,
          "transitions" => transitions_to_array(lc.transitions),
        }
      end

      def transitions_to_array(transitions)
        return [] unless transitions
        result = []
        transitions.each do |command_name, entry|
          to_state, from_raw =
            if entry.respond_to?(:target)
              [entry.target, entry.respond_to?(:from) ? entry.from : nil]
            elsif entry.is_a?(Hash)
              [entry[:target] || entry["target"], entry[:from] || entry["from"]]
            else
              [entry.to_s, nil]
            end
          # Expand from: [a, b] into multiple transitions, one per source state.
          # Canonical shape is "one transition per (command, to, from)" — both
          # parsers must produce the same flat list.
          from_states = from_raw.is_a?(Array) ? from_raw : [from_raw]
          from_states.each do |from_state|
            result << {
              "command" => command_name.to_s,
              "to_state" => to_state,
              "from_state" => from_state,
            }
          end
        end
        result
      end

      def dump_policy(pol)
        {
          "name"            => pol.name,
          "on_event"        => pol.event_name,
          "trigger_command" => pol.trigger_command,
          "target_domain"   => pol.respond_to?(:target_domain) ? pol.target_domain : nil,
        }
      end

      def dump_fixture(f)
        pairs = (f.attributes || {}).map { |k, v| [k.to_s, normalize_value(fixture_value(v))] }
        {
          "name"           => (f.respond_to?(:name) ? f.name : nil),
          "aggregate_name" => f.aggregate_name,
          "attributes"     => pairs,
        }
      end

      # Render a Ruby fixture value as the source-text token Rust would emit:
      # arrays as [a, b], hashes as { k: v }, strings as their content (Rust
      # already unwraps the quotes for fixture string values).
      def fixture_value(v)
        case v
        when Array  then "[#{v.map { |e| fixture_value_inner(e) }.join(', ')}]"
        when Hash   then "{ #{v.map { |k, val| "#{k}: #{fixture_value_inner(val)}" }.join(', ')} }"
        when Symbol then ":#{v}"
        when nil    then ""
        else v.to_s
        end
      end

      def fixture_value_inner(v)
        case v
        when String then "\"#{v}\""
        when Symbol then ":#{v}"
        when Array  then "[#{v.map { |e| fixture_value_inner(e) }.join(', ')}]"
        when Hash   then "{ #{v.map { |k, val| "#{k}: #{fixture_value_inner(val)}" }.join(', ')} }"
        else v.to_s
        end
      end

      # Strip whitespace adjacent to brackets/braces/parens — matches Rust's
      # normalize_value in dump.rs. Both sides apply this so the canonical
      # output agrees regardless of source whitespace.
      def normalize_value(s)
        out = String.new(capacity: s.length)
        in_str = false
        prev = ""
        chars = s.chars
        chars.each_with_index do |c, i|
          if c == '"' && prev != '\\'
            in_str = !in_str
            out << c
          elsif (c == ' ' || c == "\t") && !in_str
            nxt = chars[i + 1] || ""
            just_after_open = ['[', '{', '('].include?(prev)
            just_before_close = [']', '}', ')'].include?(nxt)
            out << c unless just_after_open || just_before_close
          else
            out << c
          end
          prev = c
        end
        out
      end

      def collect_all_policies(domain)
        agg_policies = domain.aggregates.flat_map { |a| (a.policies || []).select(&:reactive?) }
        domain_policies = (domain.policies || []).select(&:reactive?)
        agg_policies + domain_policies
      end

      def category_for(domain)
        # Only the explicit `category "X"` keyword sets category. The
        # subdomain shortcuts (`core`, `supporting`, `generic`) set
        # subdomain — different field. Don't conflate.
        return domain.category if domain.respond_to?(:category) && domain.category
        nil
      end

      # Rust treats `description` and `goal` as the same field on commands
      # (both feed cmd.description). Ruby keeps them separate. Mirror Rust:
      # prefer `description`, fall back to `goal`.
      def command_description(cmd)
        return cmd.description if cmd.description && !cmd.description.empty?
        return cmd.goal if cmd.respond_to?(:goal) && cmd.goal && !cmd.goal.empty?
        nil
      end

      def primary_role(cmd)
        return nil unless cmd.respond_to?(:actors) && cmd.actors
        first = cmd.actors.first
        return nil unless first
        first.respond_to?(:name) ? first.name : first.to_s
      end

      def emit_string(emits)
        return nil unless emits
        return emits.first if emits.is_a?(Array)
        emits.to_s
      end

      def type_string(t)
        return t.to_s if t.is_a?(Class)
        t.to_s
      end

      # ── Hecksagon DSL canonical dump ──────────────────────────
      #
      # Mirrors storehouse/src/main.rs :: dump_hecksagon_json. Only the
      # fields the Rust IR models are included — Ruby-only fields
      # (capabilities, concerns, annotations, context_map, ...) are
      # intentionally outside the canonical shape. Files that depend on
      # them go in parity/hecksagon_known_drift.txt.
      def dump_hecksagon(hex)
        {
          # Normalize nil → "" so anonymous `Hecks.hecksagon do ... end`
          # files match the Rust parser (which defaults `name: String` to
          # the empty string when the quoted-name slot is absent).
          "name"             => hex.name.to_s,
          # Phase 1 of adapter-family activation : files declared with
          # `Hecks.adapter_family` / `Hecks.provider` / `Hecks.behavior_kind`
          # carry the meta-layer kind. Plain `Hecks.hecksagon` files leave
          # this nil. Both halves must emit byte-equal canonical JSON, so
          # the field is unconditionally present.
          "framework_kind"   => (hex.respond_to?(:framework_kind) ? hex.framework_kind : nil),
          "persistence"      => hecksagon_persistence(hex),
          "subscriptions"    => Array(hex.subscriptions).map(&:to_s),
          "io_adapters"      => Array(hex.respond_to?(:io_adapters) ? hex.io_adapters : [])
                                  .map { |io| dump_io_adapter(io) },
          "shell_adapters"   => Array(hex.shell_adapters).map { |sa| dump_shell_adapter(sa) },
          "llm_adapters"     => Array(hex.respond_to?(:llm_adapters) ? hex.llm_adapters : [])
                                  .map { |la| dump_llm_adapter(la) },
          # i220 sub-gap 5 — compute adapter family parity dump.
          "compute_adapters" => Array(hex.respond_to?(:compute_adapters) ? hex.compute_adapters : [])
                                  .map { |ca| dump_compute_adapter(ca) },
          "gates"            => Array(hex.gates).map { |g| dump_gate(g) },
        }.tap do |h|
          # FQN port-verb binds (persisted_by / charged_by / imaged_by / ...).
          # GATED on non-empty to mirror storehouse/src/main.rs ::
          # dump_hecksagon_json, which adds the `bindings` key ONLY when binds
          # exist — so the bind-less files stay byte-equal (key absent both halves).
          binds = Array(hex.respond_to?(:bindings) ? hex.bindings : [])
          unless binds.empty?
            h["bindings"] = binds.map do |b|
              {
                "aggregate" => b[:aggregate].to_s, "verb"    => b[:verb].to_s,
                "adapter"   => b[:adapter].to_s,   "on"      => b[:on].to_s,
                "success"   => b[:success].to_s,   "failure" => b[:failure].to_s,
              }
            end
          end
        end
      end

      # i220 sub-gap 5 — compute adapter family parity dump.
      # Mirrors storehouse/src/main.rs :: dump_hecksagon_json's
      # compute_adapters projection. The shape carries `function_name`
      # in place of llm's `prompt_template` / `model` / `max_tokens` /
      # `backend` (no prompt + no provider for compute adapters).
      def dump_compute_adapter(ca)
        {
          "name"                 => ca.name.to_s,
          "function_name"        => ca.function_name.to_s,
          "trigger_on"           => ca.trigger_on,
          "response_into_target" => ca.response_into_target,
          "response_into_attr"   => ca.response_into_attr&.to_s,
        }
      end

      # Mirrors storehouse/src/main.rs :: dump_hecksagon_json's
      # llm_adapters projection. Ruby holds the response routing as
      # two attributes (target + attr) ; the canonical shape mirrors
      # both fields so the parity diff is byte-equal.
      def dump_llm_adapter(la)
        {
          "name"                 => la.name.to_s,
          "prompt_template"      => la.prompt_template.to_s,
          "model"                => la.model,
          "max_tokens"           => la.max_tokens,
          "trigger_on"           => la.trigger_on,
          "response_into_target" => la.response_into_target,
          "response_into_attr"   => la.response_into_attr&.to_s,
          "backend"              => la.backend&.to_s,
        }
      end

      # Rust stores IO adapter option values as the raw source slice
      # (e.g. `"."` for `root: "."` ; `["PATH"]` for `keys: ["PATH"]`).
      # Ruby gets the parsed Ruby value at DSL time ; `Object#inspect`
      # round-trips most literal forms — strings, arrays, symbols,
      # numbers — back to the source repr that Rust captured. Value-
      # types we don't expect (Procs, custom objects) fall back to
      # `inspect` too, which will drift loudly if they ever appear.
      def dump_io_adapter(io)
        {
          "kind"      => io.kind.to_s,
          "options"   => Array(io.options).map { |k, v| [k.to_s, io_option_value_repr(v)] },
          "on_events" => Array(io.on_events).map(&:to_s),
        }
      end

      def io_option_value_repr(value)
        value.inspect
      end

      def hecksagon_persistence(hex)
        # i728 — unwired persistence is None on BOTH sides. Rust no longer
        # normalizes an absent adapter to "memory" (the parse-time normalization
        # was removed when `None` became the explicit "unwired" signal). The
        # canonical IR mirrors that: absent `persistence` dumps nil ; an explicit
        # `adapter :memory|:heki|:sqlite` dumps its type string.
        return nil unless hex.persistence
        hex.persistence[:type]&.to_s
      end

      def dump_shell_adapter(sa)
        env_pairs = (sa.env || {}).map { |k, v| [k.to_s, v.to_s] }
        {
          "name"          => sa.name.to_s,
          "command"       => sa.command,
          "args"          => Array(sa.args).map(&:to_s),
          "output_format" => (sa.output_format || :text).to_s,
          "timeout"       => sa.timeout,
          "working_dir"   => sa.working_dir,
          "env"           => env_pairs,
          "ok_exit"       => sa.respond_to?(:ok_exit) ? (sa.ok_exit || 0) : 0,
        }
      end

      def dump_gate(g)
        # Ruby's GateDefinition has `allowed_methods`; Rust's Gate has
        # `allowed_commands`. Same concept, different names — canonical
        # shape is "allowed".
        allowed = g.respond_to?(:allowed_methods) ? g.allowed_methods : g.allowed_commands
        {
          "aggregate" => g.aggregate.to_s,
          "role"      => g.role.to_s,
          "allowed"   => Array(allowed).map(&:to_s),
        }
      end

      # ── World DSL canonical dump ──────────────────────────────
      #
      # Delegates to `Hecksagon::Structure::World#to_canonical_h`, which
      # mirrors `storehouse/src/main.rs :: dump_world_json`.
      def dump_world(world)
        world.to_canonical_h
      end

      # ── Behaviors DSL canonical dump ──────────────────────────
      #
      # Mirrors storehouse/src/behaviors_dump.rs. The Ruby and Rust
      # parsers both produce this shape from a `_behavioral_tests.bluebook`
      # file (top-level `Hecks.behaviors`).
      def dump_test_suite(suite)
        {
          "name"   => suite.name,
          "vision" => suite.vision,
          "tests"  => (suite.tests || []).map { |t| dump_test(t) },
        }
      end

      def dump_test(t)
        {
          "description"   => t.description,
          "tests_command" => t.tests_command,
          "on_aggregate"  => t.on_aggregate,
          "kind"          => t.kind.to_s,
          "setups"        => (t.setups || []).map { |s| dump_test_setup(s) },
          "input"         => dump_test_args(t.input),
          "expect"        => dump_test_args(t.expect),
        }
      end

      def dump_test_setup(s)
        {
          "command" => s.command,
          "args"    => dump_test_args(s.args),
        }
      end

      # Args render as ordered [key, value] pairs matching Rust's
      # BTreeMap traversal — both sides emit alphabetical key order.
      def dump_test_args(args)
        (args || {}).sort_by { |k, _| k.to_s }.map { |k, v| [k.to_s, test_arg_value(v)] }
      end

      # Render an arg value as the source-text token Rust emits.
      # Strings unwrap; symbols become :sym; arrays/hashes serialize
      # with the same ` { k: v, ... } ` spacing the Rust parser
      # captures from the source. Mirrors fixture_value_inner — the
      # canonical contract for non-trivial value tokens.
      def test_arg_value(v)
        case v
        when String  then v
        when Symbol  then ":#{v}"
        when Array   then "[#{v.map { |e| fixture_value_inner(e) }.join(', ')}]"
        when Hash    then "{ #{v.map { |k, val| "#{k}: #{fixture_value_inner(val)}" }.join(', ')} }"
        when nil     then ""
        else v.to_s
        end
      end
    end
  end
end

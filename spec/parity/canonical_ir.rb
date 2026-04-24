# Hecks::Parity::CanonicalIR
#
# Walks a Hecks::BluebookModel::Structure::Domain and emits canonical JSON
# matching the shape that hecks-life dump produces. This is the parity
# contract — both parsers must produce equivalent JSON for the same .bluebook.
#
# When the JSONs disagree, that is drift.
#
# The canonical shape is documented in hecks_life/src/dump.rs. Field naming
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
        {
          "name"       => domain.name,
          "category"   => category_for(domain),
          "vision"     => domain.vision,
          "aggregates" => domain.aggregates.map { |a| dump_aggregate(a) },
          "policies"   => all_policies.map { |p| dump_policy(p) },
          "fixtures"   => (domain.fixtures || []).map { |f| dump_fixture(f) },
        }
      end

      def dump_aggregate(agg)
        {
          "name"          => agg.name,
          "description"   => agg.description,
          "attributes"    => (agg.attributes || []).map { |a| dump_attribute(a) },
          "value_objects" => (agg.value_objects || []).map { |vo| dump_value_object(vo) },
          "references"    => (agg.references || []).map { |r| dump_reference(r) },
          "commands"      => (agg.commands || []).map { |c| dump_command(c) },
          "queries"       => (agg.queries || []).map { |q| dump_query(q) },
          "lifecycle"     => agg.lifecycle && dump_lifecycle(agg.lifecycle),
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
        {
          "name"   => ref.name.to_s,
          "target" => ref.type, # Ruby calls it `type`, canonical is `target`
          "domain" => ref.domain,
        }
      end

      def dump_command(cmd)
        {
          "name"        => cmd.name,
          "description" => command_description(cmd),
          "role"        => primary_role(cmd),
          "emits"       => emit_string(cmd.emits),
          "attributes"  => (cmd.attributes || []).map { |a| dump_attribute(a) },
          "references"  => (cmd.references || []).map { |r| dump_reference(r) },
          "givens"      => (cmd.respond_to?(:givens) && cmd.givens || []).map { |g| dump_given(g) },
          "mutations"   => (cmd.respond_to?(:mutations) && cmd.mutations || []).map { |m| dump_mutation(m) },
        }
      end

      def dump_query(q)
        {
          "name"        => q.name.to_s,
          "description" => q.respond_to?(:description) ? q.description : nil,
        }
      end

      def dump_given(g)
        {
          "expression" => g.respond_to?(:expression) ? g.expression : g.to_s,
          "message"    => g.respond_to?(:message) ? g.message : nil,
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
      # Mirrors hecks_life/src/main.rs :: dump_hecksagon_json. Only the
      # fields the Rust IR models are included — Ruby-only fields
      # (capabilities, concerns, annotations, context_map, ...) are
      # intentionally outside the canonical shape. Files that depend on
      # them go in spec/parity/hecksagon_known_drift.txt.
      def dump_hecksagon(hex)
        {
          # Normalize nil → "" so anonymous `Hecks.hecksagon do ... end`
          # files match the Rust parser (which defaults `name: String` to
          # the empty string when the quoted-name slot is absent).
          "name"           => hex.name.to_s,
          "persistence"    => hecksagon_persistence(hex),
          "subscriptions"  => Array(hex.subscriptions).map(&:to_s),
          "io_adapters"    => Array(hex.respond_to?(:io_adapters) ? hex.io_adapters : [])
                                .map { |io| dump_io_adapter(io) },
          "shell_adapters" => Array(hex.shell_adapters).map { |sa| dump_shell_adapter(sa) },
          "gates"          => Array(hex.gates).map { |g| dump_gate(g) },
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
        # Rust defaults unspecified persistence to "memory" in a post-parse
        # normalization step (hecks_life/src/hecksagon_parser.rs). The canonical
        # IR matches that default: absent `persistence` means memory. Ruby's
        # DomainContext stores the persistence hash on the block form and
        # leaves it nil on the shorthand / absent form — both canonicalize to
        # "memory".
        return "memory" unless hex.persistence
        hex.persistence[:type]&.to_s || "memory"
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
      # mirrors `hecks_life/src/main.rs :: dump_world_json`.
      def dump_world(world)
        world.to_canonical_h
      end

      # ── Behaviors DSL canonical dump ──────────────────────────
      #
      # Mirrors hecks_life/src/behaviors_dump.rs. The Ruby and Rust
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

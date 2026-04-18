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
          "description" => cmd.description,
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
          "name"        => q.name,
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
          "value" => mutation_value(m.value),
        }
      end

      # Preserve the leading colon for Symbol values — `:label` means
      # "bind from the :label parameter," not the literal string "label".
      # Rust keeps the colon in source text; Ruby must too.
      def mutation_value(v)
        case v
        when Symbol then ":#{v}"
        when nil    then nil
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
        transitions.map do |command_name, entry|
          to_state, from_state =
            if entry.respond_to?(:target)
              [entry.target, entry.respond_to?(:from) ? entry.from : nil]
            elsif entry.is_a?(Hash)
              [entry[:target] || entry["target"], entry[:from] || entry["from"]]
            else
              [entry.to_s, nil]
            end
          { "command" => command_name.to_s, "to_state" => to_state, "from_state" => from_state }
        end
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
        pairs = (f.attributes || {}).map { |k, v| [k.to_s, v.to_s] }
        { "aggregate_name" => f.aggregate_name, "attributes" => pairs }
      end

      def collect_all_policies(domain)
        agg_policies = domain.aggregates.flat_map { |a| (a.policies || []).select(&:reactive?) }
        domain_policies = (domain.policies || []).select(&:reactive?)
        agg_policies + domain_policies
      end

      def category_for(domain)
        return domain.metadata[:category] if domain.respond_to?(:metadata) && domain.metadata.is_a?(Hash) && domain.metadata[:category]
        return domain.subdomain.to_s if domain.respond_to?(:subdomain) && domain.subdomain
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
    end
  end
end

# GENERATED — projected from the language's own Keyword rows (the
# `calls:`, `resolves_via:` and `disambiguator:` columns of every
# KeywordSeed under lib/hecks/language/).
#
# DO NOT EDIT. spec/bootstrap_table_spec.rb re-projects this in memory
# and refuses a diff — run bin/project_bootstrap_table instead.
#
# Plain data, no requires: this is read WHILE the grammar table it was
# projected from is still being built (`MetaValidator.bootstrapping?`).

module Hecks
  module Bluebook
    module DSL
      module BootstrapTable
        # [context, word] => the method a word's whole call forwards to.
        CALLS = {
          ["Aggregate", "provenance"] => :provenance_impl,
          ["Aggregate", "identified_by"] => :identified_by_impl,
          ["Aggregate", "reference_to"] => :reference_to_impl,
          ["Aggregate", "has_many"] => :has_many_impl,
          ["Aggregate", "has_one"] => :has_one_impl,
          ["Aggregate", "belongs_to"] => :belongs_to_impl,
          ["Aggregate", "lifecycle"] => :lifecycle_impl,
          ["Aggregate", "entity"] => :entity_impl,
          ["Aggregate", "query"] => :query_impl,
          ["Aggregate", "policy"] => :policy_impl,
          ["Aggregate", "command"] => :command_impl,
          ["Aggregate", "attribute"] => :attribute_impl,
          ["Aggregate", "invariant"] => :invariant_impl,
          ["Aggregate", "given"] => :given_impl,
          ["Aggregate", "projects"] => :projects_impl,
          ["Lifecycle", "transition"] => :transition_impl,
          ["Bluebook", "attaches_to"] => :attaches_to_impl,
          ["Bluebook", "provides"] => :provides_impl,
          ["Bluebook", "aggregate"] => :aggregate_impl,
          ["Command", "role"] => :role_impl,
          ["Command", "provenance"] => :provenance_impl,
          ["Command", "reference_to"] => :reference_to_impl,
          ["Command", "given"] => :given_impl,
          ["Command", "sets"] => :sets_impl,
          ["Command", "then_set"] => :then_set_impl,
          ["Command", "delegates_to"] => :delegates_to_impl,
          ["Command", "attribute"] => :attribute_impl,
          ["Command", "corrects"] => :corrects_impl,
          ["Entity", "identified_by"] => :identified_by_impl,
          ["Entity", "given"] => :given_impl,
          ["Entity", "invariant"] => :invariant_impl,
          ["Entity", "command"] => :command_impl,
          ["Entity", "query"] => :query_impl,
          ["Entity", "lifecycle"] => :lifecycle_impl,
          ["Entity", "attribute"] => :attribute_impl,
          ["Entity", "reference_to"] => :reference_to_impl,
          ["Entity", "has_many"] => :has_many_impl,
          ["Entity", "has_one"] => :has_one_impl,
          ["Entity", "belongs_to"] => :belongs_to_impl,
          ["Entity", "entity"] => :entity_impl,
          ["Policy", "on"] => :on_impl,
          ["Policy", "trigger"] => :trigger_impl,
          ["Policy", "across"] => :across_impl,
          ["ProcessManager", "starts_on"] => :starts_on_impl,
          ["ProcessManager", "ends_on"] => :ends_on_impl,
          ["ProcessManager", "transition"] => :transition_impl,
          ["Handler", "dispatch"] => :dispatch_impl,
          ["Dispatch", "compensates"] => :compensates_impl,
          ["ReadModel", "reference_to"] => :reference_to_impl,
          ["ReadModel", "include"] => :include_impl,
          ["ReadModel", "group_by"] => :group_by_impl,
          ["ReadModel", "where"] => :where_impl,
          ["ReadModel", "order_by"] => :order_by_impl,
          ["ReadModel", "authorize"] => :authorize_impl,
          ["Query", "attribute"] => :attribute_impl,
          ["Query", "reference_to"] => :reference_to_impl,
          ["Query", "where"] => :where_impl,
          ["Query", "order_by"] => :order_by_impl,
          ["Query", "authorize"] => :authorize_impl,
          ["ValueObject", "attribute"] => :attribute_impl,
          ["ValueObject", "one_of"] => :one_of_impl,
          ["ValueObject", "invariant"] => :invariant_impl,
          ["ValueObject", "member"] => :member_impl,
          ["OneOf", "member"] => :member_impl,
          ["Type", "list_of"] => :list_of_impl,
          ["Type", "one_of"] => :one_of_impl,
          ["World", "realm"] => :realm_impl,
          ["World", "latest"] => :latest_impl,
          ["DomainPort", "operation"] => :tells_impl,
          ["DomainPort", "tells"] => :tells_impl,
          ["DomainPort", "asks"] => :asks_impl,
          ["Hecksagon", "port"] => :port_impl,
          ["PortOperation", "reference_to"] => :reference_to_impl,
          ["PortOperation", "attribute"] => :attribute_impl,
          ["Translation", "aggregate"] => :aggregate_impl,
          ["TranslationAggregate", "rename"] => :rename_impl,
          ["TranslationAggregate", "move"] => :move_impl,
          ["TranslationAggregate", "convert"] => :convert_impl,
          ["TranslationAggregate", "retype"] => :retype_impl,
          ["TranslationAggregate", "compute"] => :compute_impl,
          ["TranslationAggregate", "rekey"] => :rekey_impl,
          ["TranslationAggregate", "backfill"] => :backfill_impl,
          ["TranslationAggregate", "unresolved"] => :unresolved_impl,
          ["Query", "limit"] => :limit_impl,
          ["Query", "offset"] => :offset_impl,
          ["ReadModel", "limit"] => :limit_impl,
          ["ReadModel", "offset"] => :offset_impl
        }.freeze

        # [word, context] => the RuleReference primitive a bare reference resolves through.
        RESOLVES = {
          ["given", "Aggregate"] => { resolves_via: "owner_keyed", disambiguator: "declared_by" }.freeze,
          ["given", "Command"] => { resolves_via: "hash_chain" }.freeze,
          ["given", "Entity"] => { resolves_via: "owner_keyed", disambiguator: "declared_by" }.freeze,
          ["invariant", "ValueObject"] => { resolves_via: "sibling_scan" }.freeze
        }.freeze
      end
    end
  end
end

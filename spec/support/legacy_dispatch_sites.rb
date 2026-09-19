require "prism"
require "hecks/codemod/legacy_dispatch_args"

# Every call site still passing command facts as loose keyword arguments,
# counted per file — the deprecation's own worklist (roadmap I3), and the
# table two guards read:
#
#   - spec_helper.rb makes the deprecation raise at any site not counted
#     here, so a new spec, a new example or a new guide cannot reintroduce
#     the shape — including through a door that forwards keywords, since
#     the site reported is the caller's own line;
#   - spec/legacy_dispatch_sites_spec.rb holds the counts to this table
#     exactly, the same two-sided ratchet spec/doc_skip_fence_caps_spec.rb
#     already applies to skip fences: over its count fails (write the new
#     call as `to:`/`with:`), under it fails too (lower the count, so the
#     site you just converted cannot quietly come back), and a file with
#     no entry counts zero.
#
# `bin/codemod_legacy_dispatch_args` is what drains it; the entries left
# are the ones no mechanical rewrite is sound for, for two reasons the
# codemod reports by name:
#
#   - **The identity rides the event payload**. A loose fact reaches the
#     emitted event whether the command declares it or not, and a policy
#     with no `with:` projection forwards that payload verbatim. Moving
#     the key into `to:` empties the field the reaction reads, and
#     restating it in `with:` is refused when the command declares no such
#     attribute (Banking's own `FreezeAccount`: "does not declare number —
#     it takes none"). Until `to:` reaches the payload, these calls have
#     no non-deprecated spelling — which is why the removal PR is gated on
#     it, not just on the release.
#   - The identity is not a string. `to:` takes a String aggregate
#     identity; an Integer entity sequence has nowhere to go yet.
#
# Everything under lib/ is migrated already: the framework's own
# forwarding doors (Router, the forms app, the CLI and JSON doors,
# Storehouse, reaction re-entry) hand their argument bag to
# `Dispatcher#dispatch_flat`, the wire form, so a loose call arriving
# through one of them is reported at the caller's line, not theirs.
module LegacyDispatchSites
  ROOT = File.expand_path("../..", __dir__)

  # Same two doors `Dispatcher` deprecates, and the same keywords that are
  # not facts.
  DOORS   = %w[dispatch dispatch_port].freeze
  ROUTING = %w[to with saga_correlation].freeze

  # The fences spec/support/doctest.rb actually executes — shared with the
  # codemod rather than restated, so the two cannot drift.
  RUNNABLE_OPENERS = Hecks::Codemod::LegacyDispatchArgs::RUNNABLE_OPENERS

  # Where an executable loose call can live: the suite, the guides and the
  # reference, the example domains, the QA corpus and the scripts. A count
  # here is not a verdict that every one of them is a real dispatch — a
  # same-named door taking its own keywords (`Storehouse.dispatch(runtime:,
  # command:)`) reads the same to a parser — only that the file may not
  # grow more of them.
  GLOBS = %w[
    spec/**/*.rb spec/**/*.bluebook
    docs/**/*.md
    examples/**/*.rb examples/**/*.bluebook
    qa/**/*.rb qa/**/*.bluebook
    bin/*
  ].freeze

  CAPS = {
    "bin/hecks_mcp_door"                                                => 1,
    "docs/HECKS_IMPLEMENTATION_PLAN.md"                                 => 3,
    "docs/hecks-survey-what-we-wish-we-had.md"                          => 1,
    "docs/implemented/guides/commands.md"                               => 1,
    "docs/implemented/guides/entities.md"                               => 8,
    "docs/implemented/guides/policies-and-process-managers.md"          => 8,
    "docs/implemented/guides/queries-and-read-models.md"                => 8,
    "docs/implemented/guides/schema-evolution.md"                       => 1,
    "docs/implemented/guides/wiring.md"                                 => 1,
    "docs/implemented/guides/writing-an-adapter.md"                     => 1,
    "docs/implemented/reference/command.md"                             => 2,
    "docs/implemented/reference/dispatch.md"                            => 2,
    "docs/implemented/reference/entity.md"                              => 8,
    "docs/implemented/reference/lifecycle.md"                           => 1,
    "docs/implemented/reference/policy.md"                              => 1,
    "docs/implemented/reference/port_operation.md"                      => 1,
    "docs/implemented/reference/query.md"                               => 1,
    "docs/rails-integration.md"                                         => 1,
    "examples/pizzas/bluebook/hecksagon/mock_stripe_payment_adapter.rb" => 1,
    "spec/act_as_spec.rb"                                               => 7,
    "spec/adapters/banking_matrix_spec.rb"                              => 7,
    "spec/adapters/driven/governance_authorization_spec.rb"             => 9,
    "spec/adapters/driven/in_process_concurrent_dispatch_spec.rb"       => 2,
    "spec/adapters/driven/local_storage_spec.rb"                        => 1,
    "spec/adapters/driven/memory_spec.rb"                               => 1,
    "spec/adapters/driven/postgres_concurrent_dispatch_spec.rb"         => 2,
    "spec/adapters/driven/postgres_era_concurrent_dispatch_spec.rb"     => 2,
    "spec/adapters/query_hop_agreement_spec.rb"                         => 13,
    "spec/banking_state_machine_spec.rb"                                => 6,
    "spec/bluebook/smoke_test_spec.rb"                                  => 1,
    "spec/construct_spec.rb"                                            => 1,
    "spec/deploy_bluebook_spec.rb"                                      => 1,
    "spec/dsl_spec.rb"                                                  => 5,
    "spec/entity_invariant_spec.rb"                                     => 5,
    "spec/events_first_class_spec.rb"                                   => 3,
    "spec/facade/cli_runner_spec.rb"                                    => 3,
    "spec/freezer_spec.rb"                                              => 6,
    "spec/fuzzing/fan_out_spec.rb"                                      => 5,
    "spec/governance_spec.rb"                                           => 7,
    "spec/identifier_numeric_coercion_growth_spec.rb"                   => 3,
    "spec/identity_spec.rb"                                             => 6,
    "spec/ledger_ordering_spec.rb"                                      => 1,
    "spec/lifecycle_value_scalar_growth_spec.rb"                        => 5,
    "spec/meta_rules_spec.rb"                                           => 5,
    "spec/mutation_append_bare_symbol_growth_spec.rb"                   => 5,
    "spec/mutation_arithmetic_absent_current_spec.rb"                   => 8,
    "spec/mutation_clamp_growth_spec.rb"                                => 8,
    "spec/mutation_float_arithmetic_growth_spec.rb"                     => 4,
    "spec/mutation_multiply_growth_spec.rb"                             => 2,
    "spec/mutation_remove_growth_spec.rb"                               => 7,
    "spec/mutation_spec.rb"                                             => 14,
    "spec/mutation_value_wrap_asymmetry_growth_spec.rb"                 => 7,
    "spec/nested_pieces_spec.rb"                                        => 7,
    "spec/oidc_projection_spec.rb"                                      => 7,
    "spec/one_of_spec.rb"                                               => 7,
    "spec/operator_conformance_spec.rb"                                 => 8,
    "spec/pizzas_spec.rb"                                               => 16,
    "spec/port_operation_interpreter_spec.rb"                           => 5,
    "spec/ports/identity_generation_spec.rb"                            => 3,
    "spec/ports/persistence/append_only_spec.rb"                        => 1,
    "spec/project_tenant_spec.rb"                                       => 1,
    "spec/qa_postgres_migration_spec.rb"                                => 3,
    "spec/quality_control_spec.rb"                                      => 6,
    "spec/query_comparators_spec.rb"                                    => 9,
    "spec/query_none_in_state_aggregate_level_growth_spec.rb"           => 6,
    "spec/query_none_in_state_growth_spec.rb"                           => 7,
    "spec/query_none_in_state_heki_spec.rb"                             => 6,
    "spec/query_none_in_state_lifecycle_spec.rb"                        => 7,
    "spec/query_paging_agreement_spec.rb"                               => 1,
    "spec/router_spec.rb"                                               => 2,
    "spec/runtime/authorization_spec.rb"                                => 2,
    "spec/runtime/boot_files_spec.rb"                                   => 2,
    "spec/runtime/card_payment_tags_hydration_spec.rb"                  => 9,
    "spec/runtime/command_rules_spec.rb"                                => 67,
    "spec/runtime/copy_from_state_spec.rb"                              => 1,
    "spec/runtime/corrects_spec.rb"                                     => 18,
    "spec/runtime/correlation_key_spec.rb"                              => 1,
    "spec/runtime/delegates_to_spec.rb"                                 => 8,
    "spec/runtime/domain_refusal_spec.rb"                               => 1,
    "spec/runtime/dry_run_spec.rb"                                      => 10,
    "spec/runtime/ensures_spec.rb"                                      => 10,
    "spec/runtime/entity_argument_gate_spec.rb"                         => 5,
    "spec/runtime/entity_list_mutations_spec.rb"                        => 17,
    "spec/runtime/entity_list_remove_spec.rb"                           => 17,
    "spec/runtime/entity_spec.rb"                                       => 13,
    "spec/runtime/freeze_accounts_on_suspension_spec.rb"                => 11,
    "spec/runtime/instance_spec.rb"                                     => 2,
    "spec/runtime/legacy_dispatch_args_deprecation_spec.rb"             => 4,
    "spec/runtime/policy_emitter_identity_spec.rb"                      => 2,
    "spec/runtime/policy_fan_out_key_spec.rb"                           => 3,
    "spec/runtime/policy_projection_spec.rb"                            => 4,
    "spec/runtime/policy_spec.rb"                                       => 17,
    "spec/runtime/postgres_era_storage_name_collision_spec.rb"          => 4,
    "spec/runtime/query_hop_spec.rb"                                    => 19,
    "spec/runtime/query_interpreter_entity_paging_spec.rb"              => 4,
    "spec/runtime/query_interpreter_offset_spec.rb"                     => 4,
    "spec/runtime/query_interpreter_spec.rb"                            => 1,
    "spec/runtime/rebuild_sweep_spec.rb"                                => 12,
    "spec/runtime/reference_shape_spec.rb"                              => 11,
    "spec/runtime/relationship_list_spec.rb"                            => 8,
    "spec/runtime/relationship_semantics_spec.rb"                       => 10,
    "spec/runtime/routing_envelope_shape_spec.rb"                       => 3,
    "spec/runtime/routing_envelope_spec.rb"                             => 6,
    "spec/runtime/safe_deposit_box_spec.rb"                             => 30,
    "spec/runtime/saga_crash_recovery_spec.rb"                          => 8,
    "spec/runtime/saga_durability_postgres_spec.rb"                     => 5,
    "spec/runtime/saga_durability_spec.rb"                              => 14,
    "spec/runtime/saga_spec.rb"                                         => 26,
    "spec/runtime/unknown_argument_spec.rb"                             => 6,
    "spec/runtime/value_object_identity_spec.rb"                        => 2,
    "spec/runtime/value_spec.rb"                                        => 4,
    "spec/scalar_value_object_spec.rb"                                  => 7,
    "spec/storehouse_spec.rb"                                           => 30,
    "spec/tenant_isolation_fuzz_spec.rb"                                => 1,
    "spec/tenant_isolation_spec.rb"                                     => 2,
    "spec/vocabulary_conformance_spec.rb"                               => 6
  }.freeze

  module_function

  # **The suite's own setting, in one place** — spec_helper.rb arms it at boot,
  # and the spec that exercises the deprecation on purpose re-arms it here
  # rather than restating the predicate and drifting from it.
  def install_suite_guard!
    return if ENV["HECKS_DEPRECATIONS"] == "warn"

    Hecks::Deprecation.raise_on!(:legacy_dispatch_args) { |site| !known?(site) }
  end

  # Is this deprecation site ("path:line", absolute or relative) one of the
  # counted ones?
  def known?(site)
    path, _, _line = site.to_s.rpartition(":")
    CAPS.key?(relative(path))
  end

  def relative(path) = path.start_with?("#{ROOT}/") ? path.delete_prefix("#{ROOT}/") : path

  # { "path" => how many loose-keyword call sites it holds }
  def scan
    files.each_with_object({}) do |path, found|
      count = count_in(path)
      found[relative(path)] = count if count.positive?
    end
  end

  def files
    GLOBS.flat_map { |glob| Dir.glob(File.join(ROOT, glob)) }
         .select { |path| File.file?(path) }
         .reject { |path| path.include?("/tmp/") }
         .sort
  end

  def count_in(path)
    return count_markdown(path) if path.end_with?(".md")

    source = File.read(path)
    return 0 unless source.include?("dispatch")
    return 0 if path.start_with?("#{ROOT}/bin/") && !source.start_with?("#!/usr/bin/env ruby")

    count_source(source)
  end

  # Only the fences doctest runs — a ```ruby skip fence is shown, never
  # executed, so nothing in it can warn.
  def count_markdown(path)
    total = 0
    block = nil
    File.read(path).each_line do |line|
      if block
        if line.strip == block[:closer]
          total += count_source(block[:code]) if block[:runnable]
          block = nil
        else
          block[:code] << line
        end
      elsif line.start_with?("```", "<!-- doctest:boot")
        opener = line.rstrip
        block = { closer: opener.start_with?("<!--") ? "-->" : "```", code: +"",
                  runnable: RUNNABLE_OPENERS.include?(opener) }
      end
    end
    total
  end

  def count_source(source)
    tree = Prism.parse(source)
    return 0 unless tree.errors.empty?

    found = []
    collect(tree.value, found)
    found.size
  end

  def collect(node, found)
    return unless node

    found << node if node.is_a?(Prism::CallNode) && DOORS.include?(node.name.to_s) && loose?(node)
    node.compact_child_nodes.each { |child| collect(child, found) }
  end

  # A keyword argument that is not `to:`/`with:`/`saga_correlation:` — a
  # double-splat counts too: whatever it carries, the door reads it as
  # loose facts.
  def loose?(call)
    keywords = call.arguments&.arguments&.last
    return false unless keywords.is_a?(Prism::KeywordHashNode)

    keywords.elements.any? do |element|
      !(element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
        ROUTING.include?(element.key.unescaped))
    end
  end
end

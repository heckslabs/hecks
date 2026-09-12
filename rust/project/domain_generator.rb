require "fileutils"
require "json"

module RustProjection
  # Generates one domain's worth of types/Fielded impls/commands into
  # `mod_dir`, plus a `metadata.rs` carrying that domain's own canonical IR
  # as an embedded JSON constant — SELF-DESCRIPTION: an app holding the
  # compiled binary can list its own commands, read `given` text, etc. at
  # runtime without a second, hand-maintained description and without going
  # back to Ruby. Nothing generated above reads `metadata.rs` — it exists
  # purely for introspection, the same way a doc comment does, just at
  # runtime instead of read-time.
  #
  # ALSO generates a `registry.rs` — the JSON command router
  # `kernel::cli.rs`'s stdin/stdout CLI dispatches through (json_codec.rb's
  # `to_json`/`from_json`/`extract_id`, registry.rb's `emit_registry`). This
  # is what makes the SAME compiled artifact wasm32-wasip1-buildable: the
  # only reason `rust/src/main.rs` used to be a hardcoded, domain-specific
  # demo is that nothing generated a way to route an arbitrary named command
  # against arbitrary JSON args; this closes that.
  module DomainGenerator
    module_function

    # `manifest_entry` — ONE LINE OF GROUND TRUTH per IR construct this
    # generator ever makes a decision about, accumulated into `call`'s own
    # `manifest` array and written out as `manifest.json` alongside
    # `ir.json` (this method's own caller, below). This exists so a
    # SEPARATE coverage tool (`bin/rust_coverage`) never has to re-derive
    # "did this generate?" by grepping generated Rust source with regexes
    # — the generator that actually MADE the decision writes it down,
    # once, at the moment it makes it. That is more trustworthy than
    # reconstruction after the fact for the same reason a git commit
    # message beats a diff summary: the author was there.
    #
    # `gap_class` distinguishes the two structurally different reasons an
    # entry can read `generated: false` (see bin/rust_coverage's own
    # header for the full argument): `"whole_kind"` means this CONSTRUCT
    # KIND has no code path in this generator at all, ever, for any
    # domain (`query`, `read_model` — nothing below ever calls anything
    # that would emit one) — the safe, self-announcing kind of gap.
    # `"per_instance"` means the kind is generated in general, but THIS
    # declared instance individually failed a specific, named check this
    # generator already runs for every one of its siblings (an
    # unsupported attribute type, a `sets` shape this generator's
    # `apply` doesn't cover yet, an identity this generator's `extract_id`
    # can't resolve) — the dangerous kind, because nine siblings
    # generating correctly makes the tenth's silence easy to miss without
    # exactly this kind of per-instance record.
    #
    # `routed` is `nil` (omitted from the JSON entirely — see below)
    # unless the construct has a real distinction between "a Rust
    # function got emitted for this" and "a JSON-dispatchable registry
    # entry routes to it" — commands and entity commands are the two
    # kinds where those can come apart (a `dispatch_*` function can exist
    # in the generated source while being genuinely unreachable through
    # `kernel::cli.rs`'s own JSON router, because the owning aggregate's
    # or entity's identity shape isn't one `extract_id` resolves). Nothing
    # else in this generator has that second axis, so nothing else sets it.
    def manifest_entry(kind:, id:, generated:, reason: nil, gap_class: nil, routed: nil)
      entry = { kind: kind, id: id, generated: generated }
      entry[:routed] = routed unless routed.nil?
      entry[:gap_class] = gap_class if gap_class
      entry[:reason] = reason if reason
      entry
    end

    def lifecycle_extra_field(node)
      return [] unless node[:lifecycle]

      field = Projector.rust_ident_field(node[:lifecycle][:field])
      [[Projector.rust_field(node[:lifecycle][:field]), "crate::kernel::Json::Str(self.#{field}.clone())"]]
    end

    # `reference_checks(command, aggregates_by_name, unsupported_names)` —
    # `CommandRules::References#resolve_references`'s own per-attribute walk
    # (`command.attributes.select(&:reference?)`), read at codegen time
    # instead of dispatch time: for each `Reference<X>` command attribute,
    # resolve `X` against every aggregate THIS domain declares (Ruby's own
    # `attribute.type.resolve` is lazy through the same chapter, so forward
    # references across aggregates in one file already work there — matched
    # here by resolving against the FULL `ir[:aggregates]` list, not just
    # the ones already written when this command's file is reached).
    # `next unless target` (Ruby) — a target this domain never declares (a
    # genuine cross-domain reference) — is `target.nil?` below; a target
    # this domain declares but couldn't itself generate (`unsupported_names`
    # — no Rust module would exist to check against) gets the same
    # treatment, though nothing in the real corpus hits that case today.
    def reference_checks(command, aggregates_by_name, unsupported_names)
      command[:attributes].filter_map do |attr|
        target_name = Projector.reference_target(attr[:type])
        next unless target_name

        target = aggregates_by_name[target_name]
        next unless target
        next if unsupported_names.include?(target_name)

        {
          field: attr[:name],
          optional: attr[:optional],
          target_mod: target[:name].downcase,
          target_name: target[:name],
          heads: target[:identified_by].map { |path| path.split(".").first }.join(", "),
        }
      end
    end

    # `state_reference_checks(aggregate, command, aggregates_by_name,
    # unsupported_names)` — `CommandRules::References#resolve_state_
    # references`' own case (references.rb, read directly), read at
    # codegen time: a SECOND, LATER check Ruby runs at `step_save`
    # against the SETTLED aggregate state, catching a reference field
    # REDECLARED on the command under a plain value object (`attribute
    # :member, Handle; sets :member` — `Referral.Reassign`'s own shape,
    # ADR 0037 Finding 5, reopened) that `reference_checks` above cannot:
    # the command's own attribute isn't `reference?`-true, so `resolve_
    # references`' (and this file's own `reference_checks`) per-attribute
    # walk sees nothing to check, even though the AGGREGATE's field of
    # the same name really is `Reference<X>`-typed.
    #
    # A full, general port of `resolve_state_references` would need the
    # SETTLED value — only known once `apply_mutations` has actually run,
    # inside the hand-written generic `dispatch` (kernel/dispatch.rs),
    # which has no access to any OTHER aggregate's repo to check against.
    # This corpus's one trigger (`SafeDepositBox.Rent`, pre-#409; now
    # `Referral.Reassign`) doesn't need that generality: a bare `sets
    # :field` mutation (no `to:`, `append:`, etc.) copies its SOURCE
    # ARGUMENT's value straight into the aggregate's field, unconditionally
    # — the settled value this check needs is already sitting in `args`,
    # BEFORE dispatch even runs. So this reuses the exact SAME check shape
    # `reference_checks` above already emits (a pre-dispatch check against
    # `args`, at the router), just resolved against the AGGREGATE's own
    # attribute instead of the command's — no new runtime code, no
    # settled-state read, no dispatch-function signature change.
    #
    # `next if Projector.reference_target(source_attr[:type])` — the
    # source argument is ALREADY `Reference<X>`-typed (`Referral.Issue`'s
    # own `member`, declared via `reference_to Member`): `reference_checks`
    # above already covers that shape; adding it again here would only
    # double-check the identical fact.
    #
    # NOT COVERED, DELIBERATELY (ADR 0037 Finding 5's own closing note):
    # a mutation shape other than a bare `:set` (nothing in the real
    # corpus revalues a reference any other way), a `has_many`/list
    # relationship, and entity-level recursion — the real corpus,
    # referral_chain included, declares zero entity-level `reference_to`
    # attributes for this to catch that the command-level check doesn't
    # already cover.
    def state_reference_checks(aggregate, command, aggregates_by_name, unsupported_names, value_objects_by_name)
      aggregate[:attributes].filter_map do |attr|
        target_name = Projector.reference_target(attr[:type])
        next unless target_name
        # BUG#25/BUG#26 interaction — this method's own header already
        # documents a `has_many`/list relationship as "not covered,
        # deliberately," but nothing here actually enforced that: a
        # `has_many` field reached this far and built a `check_reference`
        # call against `args.<field>.value` — a single-field accessor
        # applied to the WHOLE Vec (`has_many_fixture`'s own `Circle.
        # Admit`, `sets :members` from a `list_of(Handle)` argument),
        # which does not compile (`no field 'value' on type Vec<Handle>`,
        # found live regenerating this fixture against BUG#26's own
        # fix). `state_reference_check_accessor` builds an ELEMENT-level
        # accessor unconditionally; a real list-aware port needs
        # `check_reference` (kernel/repository.rs) to walk each element,
        # which nothing in the real corpus needs yet — matching this
        # header's own already-stated scope, just actually applied now.
        next if attr[:list]

        mutation = command[:mutations].find do |m|
          m[:op].to_s == "set" && m[:target].to_s == attr[:name].to_s && m[:source][:kind] == "argument"
        end
        next unless mutation

        source_attr = command[:attributes].find { |a| a[:name].to_s == mutation[:source][:name].to_s }
        next unless source_attr
        next if Projector.reference_target(source_attr[:type])

        accessor = state_reference_check_accessor(source_attr, value_objects_by_name)
        next unless accessor

        target = aggregates_by_name[target_name]
        next unless target
        next if unsupported_names.include?(target_name)

        {
          field: accessor,
          optional: source_attr[:optional],
          target_mod: target[:name].downcase,
          target_name: target[:name],
          heads: target[:identified_by].map { |path| path.split(".").first }.join(", "),
        }
      end
    end

    # `state_reference_check_accessor(source_attr, value_objects_by_name)`
    # — the SOURCE ARGUMENT's own field-access expression, tacked onto
    # `args.` by `emit_reference_check` (registry.rb). A plain scalar
    # argument (`Projector.effective_scalar_type` non-nil — a reference-
    # typed attribute is already excluded by `state_reference_checks`'
    # own caller) is a raw `String`/etc already, same shape as an
    # ordinary `Reference<X>` command attribute: `nil` here means "use
    # the field name as-is."
    #
    # A SINGLE-attribute value object (this corpus's own dominant
    # convention — `Handle`, `Code`, ...) is a real Rust struct wrapping
    # that one field (`referral.rs`'s own `Handle { value: String }`), so
    # the check needs `.{that field}` appended — but ONLY for a REQUIRED
    # argument: `check_reference`'s optional-argument template already
    # assumes `Option<String>` (an ordinary optional `Reference<X>`
    # attribute), not `Option<Handle>`, and teaching it to unwrap an
    # `Option<Struct>` too is real, separate codegen work nothing in the
    # real corpus needs yet (`Referral.Reassign`'s own `member` is
    # required). A multi-attribute value object has no single field to
    # dot into (Ruby's own `reference_key`, references.rb, joins every
    # field via `Naming.identity` for that shape) — also not attempted.
    # `nil` for both: an honest, narrow gap over a shape the real corpus
    # doesn't exercise, matching ADR 0037 Finding 5's own "not covered,
    # deliberately" precedent.
    def state_reference_check_accessor(source_attr, value_objects_by_name)
      return source_attr[:name] if Projector.effective_scalar_type(source_attr[:type])

      vo = value_objects_by_name[source_attr[:type]]
      return nil unless vo
      return nil if source_attr[:optional]
      return nil unless vo[:attributes].size == 1

      "#{source_attr[:name]}.#{Projector.rust_ident_field(vo[:attributes].first[:name])}"
    end

    def call(ir, source_label, mod_dir, mod_name)
      FileUtils.mkdir_p(mod_dir)
      domain_name = ir[:name]
      generated_aggregates = []
      registry_aggregates = []
      # THE COVERAGE MANIFEST — see `manifest_entry`'s own header. One
      # entry per construct this call makes a generate/skip decision
      # about; written to `manifest.json` at the end of this method,
      # alongside the `ir.json` sidecar this method already writes.
      manifest = []
      # ONE ENTRY PER GENERATED NAMED QUERY — `queries.rb`'s own
      # `query_conditions` output, accumulated the same way
      # `registry_aggregates` is: written into THIS chapter's own
      # `registry.rs` below, and RETURNED so a multi-chapter caller
      # (`bin/project_rust`'s merged registry) can union it with every
      # OTHER chapter's own query_defs the same way it already unions
      # `registry_aggregates`.
      query_defs = []
      aggregates_by_name = ir[:aggregates].to_h { |a| [a[:name], a] }
      unsupported_names = ir[:aggregates].select do |a|
        vo_by_name = a[:value_objects].to_h { |vo| [vo[:name], vo] }
        Projector.unsupported_attribute_types(a, vo_by_name).any?
      end.map { |a| a[:name] }
      # WHICH AGGREGATE OWNS EACH VALUE OBJECT, across this WHOLE domain —
      # a COMMAND's own attribute can name ANY value object the domain
      # declares, not just one its own owner also happens to declare
      # (`Banking::SafeDepositBox.Rent`'s own `attribute :customer,
      # CustomerNumber` — `CustomerNumber` is `Customer`'s own, never
      # `SafeDepositBox`'s). `cross_aggregate_vo_imports`, below, is the
      # ONLY reader — a struct field/from_json/to_json's own type name
      # (`Projector.rust_type`/`rust_ident`) still emits the SAME bare
      # identifier it always did; what makes that identifier resolve for
      # a FOREIGN type is a `use` line at the top of the generated file,
      # not a qualified path threaded through every codegen call site.
      domain_value_object_owner = ir[:aggregates].each_with_object({}) do |a, index|
        a[:value_objects].each { |vo| index[vo[:name]] = a[:name] }
      end
      # THE VALUE OBJECTS THEMSELVES, same domain-wide reach — `bridging.
      # rb`'s own `bridgeable_value_types?`/`value_rhs` need the actual
      # DEFINITION (not just which aggregate owns it) to bridge a
      # cross-aggregate command argument's type into its target field.
      # Merged into each aggregate's own LOCAL map below with the local
      # map winning any name collision — nothing that already resolved
      # locally ever starts resolving to a different definition; this
      # only ever adds a name a purely local map didn't have. Never
      # iterated (only ever looked up by name), so widening it changes
      # nothing about what any OTHER reader of a per-aggregate `value_
      # objects_by_name` already saw.
      domain_value_objects_by_name = ir[:aggregates].flat_map { |a| a[:value_objects] }.to_h { |vo| [vo[:name], vo] }
      ir[:aggregates].each do |aggregate|
        value_objects_by_name = domain_value_objects_by_name.merge(aggregate[:value_objects].to_h { |vo| [vo[:name], vo] })
        # BEFORE anything below reads a single `attr[:optional]` off an
        # entity/value-object field — every one of those reads (the
        # struct-field wrap two loops down, `command_skip_reason`'s own
        # optional-source check) needs to see the derived fact, not just
        # whatever the domain author wrote by hand (mutations.rb's own
        # header on why this is safe to run unconditionally, every time).
        Projector.mark_append_optional_fields!(aggregate, value_objects_by_name)
        Projector.derive_reverses_mutations!(aggregate)

        unsupported = Projector.unsupported_attribute_types(aggregate, value_objects_by_name)
        if unsupported.any?
          aggregate_reason = "attribute type(s) #{unsupported.join(', ')} not generated yet " \
                              "(a bare, non-list entity-typed attribute isn't resolved to a Rust type)"
          puts "skipping #{domain_name}::#{aggregate[:name]}: #{aggregate_reason}"
          manifest << manifest_entry(kind: "aggregate", id: "#{domain_name}::#{aggregate[:name]}", generated: false,
                                      gap_class: "per_instance", reason: aggregate_reason)
          # CASCADE, not silence: every command/entity-command/port-op this
          # skipped aggregate owns was never even considered for its OWN
          # per-instance checks (`command_skip_reason` etc. all need a
          # generated record type to check field-bridging against) — so
          # each gets its own entry here, tracing back to this same root
          # cause, rather than just vanishing from the manifest along with
          # the aggregate itself.
          aggregate[:commands].each do |command|
            manifest << manifest_entry(kind: "command", id: "#{domain_name}::#{aggregate[:name]}.#{command[:name]}",
                                        generated: false, gap_class: "per_instance",
                                        reason: "owning aggregate not generated: #{aggregate_reason}")
          end
          aggregate[:entities].each do |entity|
            manifest << manifest_entry(kind: "entity", id: "#{domain_name}::#{aggregate[:name]}.#{entity[:name]}",
                                        generated: false, gap_class: "per_instance",
                                        reason: "owning aggregate not generated: #{aggregate_reason}")
            entity[:commands].each do |command|
              manifest << manifest_entry(kind: "entity_command",
                                          id: "#{domain_name}::#{aggregate[:name]}.#{entity[:name]}.#{command[:name]}",
                                          generated: false, gap_class: "per_instance",
                                          reason: "owning aggregate not generated: #{aggregate_reason}")
            end
          end
          aggregate[:ports].each do |port|
            port[:operations].each do |operation|
              manifest << manifest_entry(kind: "port_operation",
                                          id: "#{domain_name}::#{aggregate[:name]}.#{port[:name]}.#{operation[:name]}",
                                          generated: false, gap_class: "per_instance",
                                          reason: "owning aggregate not generated: #{aggregate_reason}")
            end
          end
          next
        end

        manifest << manifest_entry(kind: "aggregate", id: "#{domain_name}::#{aggregate[:name]}", generated: true)
        generated_aggregates << aggregate
        can_route = Projector.extract_id_supported?(aggregate)
        registry_commands = []
        entity_commands = []
        nested_entity_commands = []
        port_operations = []
        record_name = Projector.rust_ident(aggregate[:name])

        path = File.join(mod_dir, "#{aggregate[:name].downcase}.rs")
        wrote = WriteIfChanged.block(path) do |f|
          f.puts "// GENERATED by bin/project_rust from #{source_label}'s canonical IR."
          f.puts "// Do not hand-edit — re-run bin/project_rust instead."
          f.puts "#![allow(dead_code, unused_variables)]"
          f.puts 'use crate::kernel::Expr;'
          Projector.cross_aggregate_vo_imports(aggregate, domain_value_object_owner, mod_name).each { |line| f.puts line }
          f.puts

          aggregate[:value_objects].each do |vo|
            f.puts Projector.emit_value_object(vo, value_objects_by_name, aggregates_by_name)
            f.puts
            if vo[:closed_set] && vo[:attributes].size == 1
              # A single-field closed set collapses to a Rust ENUM
              # (emit_value_object's own branch) — needs the tag<->member
              # codec.
              f.puts Projector.emit_closed_set_codec(vo)
            elsif vo[:closed_set]
              # A multi-field closed set (`StatementFrequency`) is a DATA
              # TABLE (emit_closed_set_table's branch) whose String fields
              # are `&'static str`, not `String` — from_json can only
              # SELECT one of the table's own fixed rows, not construct a
              # fresh one (emit_closed_set_table_codec's own header).
              f.puts Projector.emit_closed_set_table_codec(vo)
            else
              # `unknown_argument_allowlist: []` — a value object gets the
              # SAME unknown-key refusal an aggregate command's own args
              # struct already gets (`emit_from_json_flat`'s own header),
              # just with no extra allowed keys beyond its own declared
              # attributes (a VO never has an `id`/reference/correlation
              # key the way a command does). Without this, a caller who
              # mistypes a nested VO field name (e.g. `{"value": 100000}`
              # for `Units`, which declares `count`) gets no refusal at
              # all whenever the REAL field carries a `default:` — the
              # generated `from_json` just falls through to that default,
              # silently discarding the caller's actual input. Found live
              # dispatching `EmbryonautFoundersApp::Member.Admit` through
              # this exact generated code: `units: {"value": 100000}`
              # saved as `{"count": 0}`, with `refusals` empty — a real,
              # silent-wrong-data class of bug, not a caller mistake this
              # generator should tolerate.
              name = Projector.rust_ident(vo[:name])
              f.puts Projector.emit_to_json_flat(name, vo[:attributes], value_objects_by_name)
              f.puts
              f.puts Projector.emit_from_json_flat(name, vo[:attributes], value_objects_by_name, unknown_argument_allowlist: [])
            end
            f.puts
          end

          aggregate[:entities].each do |entity|
            entity_verb = "#{domain_name}::#{aggregate[:name]}.#{entity[:name]}"
            manifest << manifest_entry(kind: "entity", id: entity_verb, generated: true)
            f.puts Projector.emit_entity(entity, value_objects_by_name)
            f.puts
            entity_name = Projector.rust_ident(entity[:name])
            f.puts Projector.emit_to_json_flat(entity_name, entity[:attributes], value_objects_by_name, extra_fields: lifecycle_extra_field(entity))
            f.puts
            f.puts Projector.emit_from_json_state(entity_name, entity[:attributes], value_objects_by_name, extra_fields: lifecycle_extra_field(entity))
            f.puts

            # S17, ADR 0026 — AN ENTITY NESTED INSIDE THIS ONE
            # (`ProcessManager.Handler.Dispatch`: `Dispatch` here is
            # `Handler`'s own `entity[:entities]`, one level past what
            # this loop otherwise ever reaches). Its struct and JSON
            # codec are real and needed the moment ANY sibling field
            # references it as a `Vec<...>` element type (`emit_entity`
            # above already resolved `dispatches: list_of(Dispatch)` to
            # `Vec<Dispatch>` — a type reference nothing before this
            # generated a definition for).
            #
            # BUG#11 (loop-parity) — ITS OWN COMMANDS ARE NOW ROUTED TOO,
            # for the ROUTED (`to: { aggregate:, entities: [...] }`)
            # addressing shape. `rust/src/kernel/routing.rs`'s own
            # `RoutingEnvelope` was already depth-agnostic (`entities:
            # Vec<String>`, `require_depth(N)` for any N — see that
            # file's own `preserves_ordered_entity_receiver_identities`
            # test, which already exercised depth 2 before this fix
            # existed) and Ruby's own `EntityElement#locate_chain` was
            # already hop-depth-agnostic by construction (one `element_
            # of` call per chain entry) — what was actually missing was
            # ONLY this generator's own dispatch-table wiring: a real,
            # bounded codegen gap, not a wire-format or architecture
            # mismatch. `emit_nested_entity_command` (commands.rb)
            # composes the SAME two hand-written, already-generic kernel
            # primitives a one-level entity command already uses —
            # `dispatch_entity` for the outer hop, `apply_entity_command`
            # (already used standalone by a DELEGATING door's own
            # `delegate_apply` shape) nested inside its own `apply_
            # mutations` closure for the inner hop — so no kernel/
            # dispatch.rs change was needed either.
            #
            # DELIBERATELY NOT GENERALIZED to a third level — still real,
            # separate, still-open scope.
            #
            # BUG#19 (loop-parity) — BUG#11 deliberately shipped ROUTED
            # ONLY (`to: { entities: [...] }`), refusing every FLAT-args
            # depth-2 dispatch (one identity head per hop —
            # `reference`/`number`/`sequence`, no `to:` at all, the SAME
            # convention `entity_arms`' own depth-1 `None =>` branch
            # already resolves via BUG#10's `extract_id`/`extract_wants`
            # fallback) with `TypeMismatch`, EVEN THOUGH Ruby's own
            # `locate_chain` never distinguished the two addressing
            # modes in the first place — `element_of` reads `args[head]`
            # per hop regardless of how many hops came before it. That
            # asymmetry is what `bin/qa_sweep nested_pieces` found live.
            # `entity_can_route` (moved up here from below, since the
            # nested loop now needs it too) gates whether the identity
            # shape supports `extract_id`/`extract_wants` at all —
            # `nested_can_route`, computed per `nested` inside the loop
            # below, is the SAME check one hop deeper. Both true is what
            # `unrouted_supported:` (on each `nested_entity_commands`
            # entry, read by `registry.rb`'s own `nested_entity_arms`)
            # actually gates — extending the two-hop router with the
            # identical `Some(route) => ... | None => ...` shape
            # `entity_arms` already has, never a new mechanism.
            entity_can_route = Projector.extract_id_supported?(entity)

            entity[:entities].each do |nested|
              nested_verb = "#{entity_verb}.#{nested[:name]}"
              manifest << manifest_entry(kind: "entity", id: nested_verb, generated: true)
              f.puts Projector.emit_entity(nested, value_objects_by_name)
              f.puts
              nested_rust_name = Projector.rust_ident(nested[:name])
              f.puts Projector.emit_to_json_flat(nested_rust_name, nested[:attributes], value_objects_by_name, extra_fields: lifecycle_extra_field(nested))
              f.puts
              f.puts Projector.emit_from_json_state(nested_rust_name, nested[:attributes], value_objects_by_name, extra_fields: lifecycle_extra_field(nested))
              f.puts
              # `identity()` — what a ROUTED dispatch needs off a doubly-
              # nested element (`matches = |el| el.identity() == hop2_id`,
              # commands.rb's own `emit_nested_entity_command`), emitted
              # unconditionally the way `entity`'s own always is.
              f.puts Projector.emit_self_identity(nested)
              f.puts

              # BUG#19 — `extract_id`/`extract_wants`, back FLAT-args
              # addressing at this depth exactly the way `entity_can_
              # route` already backs it one hop shallower (below,
              # `entity`'s own). Needs BOTH hops' identity shape to
              # support it — a flat dispatch has to resolve `hop1_id`
              # off `entity`'s own `extract_id` too (registry.rb's own
              # `nested_entity_arms`, `None =>` branch) — so this is
              # gated on `entity_can_route && nested_can_route`, not
              # `nested_can_route` alone.
              nested_can_route = Projector.extract_id_supported?(nested)
              unrouted_supported = entity_can_route && nested_can_route
              if unrouted_supported
                f.puts Projector.emit_extract_id(nested)
                f.puts
                f.puts Projector.emit_extract_wants(nested)
                f.puts
              else
                reason = entity_can_route ? "identity #{nested[:identified_by].inspect} isn't a shape extract_id resolves yet (json_codec.rb)" : "entity #{entity[:name]}'s own identity isn't extract_id-supported either"
                puts "skipping #{nested_verb}'s flat-args fallback: #{reason} — routed (`to:`) addressing still works"
              end

              nested[:commands].each do |command|
                nested_command_verb = "#{nested_verb}.#{command[:name]}"
                reason = Projector.entity_command_skip_reason(command, nested, value_objects_by_name)
                if reason
                  puts "skipping #{nested_command_verb}: #{reason}"
                  manifest << manifest_entry(kind: "entity_command", id: nested_command_verb, generated: false,
                                              gap_class: "per_instance", reason: reason)
                  next
                end

                f.puts Projector.emit_nested_entity_command(command, nested, entity, aggregate, domain_name, value_objects_by_name, aggregates_by_name,
                                                             process_managers: ir[:process_managers])
                f.puts

                manifest << manifest_entry(kind: "entity_command", id: nested_command_verb, generated: true, routed: true,
                                            reason: unrouted_supported ? "routed (`to: { entities: [...] }`) and flat-args (one identity head per hop) both supported (BUG#19)" : "routed (`to: { entities: [...] }`) only — no legacy/flat-argument fallback at this depth (identity shape isn't extract_id-supported at one or both hops; BUG#19's own gate)")

                nested_entity_commands << {
                  verb: nested_command_verb,
                  name: command[:name],
                  entity_record: Projector.rust_ident(entity[:name]),
                  nested_record: nested_rust_name,
                  # Matches commands.rb's `emit_nested_entity_command` naming
                  # exactly: `dispatch_entity_#{entity.downcase}_#{nested.downcase}_#{dispatch_fn_name(cmd)}`.
                  fn: "#{entity[:name].downcase}_#{nested[:name].downcase}_#{Projector.dispatch_fn_name(Projector.rust_ident(command[:name]))}",
                  args_struct: "#{nested_rust_name}#{Projector.rust_ident(command[:name])}NestedEntityArgs",
                  reference_checks: reference_checks(command, aggregates_by_name, unsupported_names),
                  reference_specs: Projector.reference_specs(domain_name, command[:attributes]),
                  attributes: command[:attributes].map { |a| a[:name].to_s },
                  role: command[:role],
                  invariant_check_lines: Projector.invariant_checks_for(command, aggregates_by_name, value_objects_by_name),
                  entity_name: entity[:name],
                  entity_identity_reading: entity[:identified_by].join(", "),
                  nested_name: nested[:name],
                  nested_identity_reading: nested[:identified_by].join(", "),
                  # BUG#19 — whether `registry.rb`'s own `nested_entity_
                  # arms` gets a `None => ...` flat-args fallback branch
                  # for THIS command, or stays the ROUTED-only shape
                  # BUG#11 shipped (both hops' identity has to support
                  # `extract_id`/`extract_wants` — see this loop's own
                  # header comment above).
                  unrouted_supported: unrouted_supported,
                }
              end
            end

            # `entity_can_route` — computed once, above, before the
            # nested-entities loop (BUG#19 needs it there too).
            entity_router_reason = "identity #{entity[:identified_by].inspect} isn't a shape extract_id resolves yet (json_codec.rb)"
            if entity_can_route
              f.puts Projector.emit_extract_id(entity)
              f.puts
              f.puts Projector.emit_extract_wants(entity)
              f.puts
              f.puts Projector.emit_self_identity(entity)
              f.puts
            else
              puts "skipping #{domain_name}::#{aggregate[:name]}.#{entity[:name]}'s JSON router entries: #{entity_router_reason}"
            end

            entity[:commands].each do |command|
              entity_command_verb = "#{domain_name}::#{aggregate[:name]}.#{entity[:name]}.#{command[:name]}"
              reason = Projector.entity_command_skip_reason(command, entity, value_objects_by_name)
              if reason
                puts "skipping #{entity_command_verb}: #{reason}"
                manifest << manifest_entry(kind: "entity_command", id: entity_command_verb, generated: false,
                                            gap_class: "per_instance", reason: reason)
                next
              end

              f.puts Projector.emit_entity_command(command, entity, aggregate, domain_name, value_objects_by_name, aggregates_by_name,
                                                   process_managers: ir[:process_managers])
              f.puts

              # THE ROUTABILITY SPLIT — this command's own Rust function
              # was just emitted above unconditionally (its OWN
              # `entity_command_skip_reason` check already passed), but
              # whether anything can DISPATCH to it depends on the
              # ENTITY's identity shape, checked once above, not this
              # command's own. When it can't, the function is real,
              # compiled, and permanently unreachable through
              # `kernel::cli.rs`'s JSON router — `generated: true,
              # routed: false` says exactly that, rather than folding it
              # into the same `generated: false` bucket a command that
              # never got a function at all would report.
              unless entity_can_route
                manifest << manifest_entry(kind: "entity_command", id: entity_command_verb, generated: true,
                                            routed: false, gap_class: "per_instance",
                                            reason: "generated as a real Rust function, but not JSON-dispatchable — #{entity_router_reason}")
                next
              end

              manifest << manifest_entry(kind: "entity_command", id: entity_command_verb, generated: true, routed: true)

              entity_commands << {
                verb: entity_command_verb,
                name: command[:name],
                entity_record: entity_name,
                # Matches commands.rb's `emit_entity_command` naming exactly:
                # `dispatch_entity_#{entity[:name].downcase}_#{dispatch_fn_name(cmd)}`.
                fn: "#{entity[:name].downcase}_#{Projector.dispatch_fn_name(Projector.rust_ident(command[:name]))}",
                # `EntityArgs`, not `Args` — an aggregate command named after the
                # entity command it delegates to (chess: `RookCastleKingside` →
                # `Rook.CastleKingside`) would otherwise share its args struct's name.
                args_struct: "#{entity_name}#{Projector.rust_ident(command[:name])}EntityArgs",
                reference_checks: reference_checks(command, aggregates_by_name, unsupported_names),
                reference_specs: Projector.reference_specs(domain_name, command[:attributes]),
                # THIS COMMAND'S OWN DECLARED ATTRIBUTE NAMES (R1) — see
                # `registry_commands`'s own identical field, above.
                attributes: command[:attributes].map { |a| a[:name].to_s },
                role: command[:role],
                # R3 FIX (docs/audits/2026-08-11-bug-triage.md) — the SAME
                # VO invariant/admits/pattern checks `emit_entity_command`
                # already bakes into the top of `dispatch_entity_*` itself,
                # computed here TOO so `registry.rb`'s own router can run
                # them BEFORE `refuse_role_mismatch`/`resolve_references`,
                # matching Ruby's own `DISPATCH_ORDER` (`normalize_args` —
                # which is where a VO's own `build` raises — precedes
                # `refuse_role_mismatch`/`resolve_references` there, both
                # of which run only after every declared argument already
                # coerced clean). Deliberately redundant with the copy
                # still inside `dispatch_entity_*` itself (unchanged,
                # `commands.rb`'s own `invariant_checks_for` call) rather
                # than removing it: every real caller reaches a generated
                # dispatch fn exclusively through this router (`kernel/
                # cli.rs`'s `dispatch_by_name`, including the dry_run and
                # reaction re-entry paths — orchestrate.rs's own header),
                # so the inner copy can only ever re-confirm what this
                # router's own copy already passed, never diverge from it.
                invariant_check_lines: Projector.invariant_checks_for(command, aggregates_by_name, value_objects_by_name),
                # `entity_element_missing`'s own `{entity}`/`{identity}` —
                # codegen-time-static off the ENTITY's own declared name/
                # `identified_by`, threaded through registry.rb's own
                # dispatch call the same way the PARENT aggregate's
                # `a[:name]`/`a[:identified_by]` already reach it (that hash
                # is the full aggregate IR node, no new field needed there).
                entity_name: entity[:name],
                entity_identity_reading: entity[:identified_by].join(", "),
              }
            end
          end

          # `record_attributes` — `aggregate[:attributes]` PLUS a
          # `String`-typed, always-optional pseudo-attribute per
          # `projects` field (`types.rb`'s own `projected_field_pseudo_
          # attributes` header) — the record's own struct/Fielded/JSON
          # shape needs to carry a seeded projection exactly like any
          # other attribute; a command's own Args struct (built
          # elsewhere, from `command[:attributes]` alone) never sees
          # this merge, since a projected field is never a command
          # argument.
          record_attributes = aggregate[:attributes] + Projector.projected_field_pseudo_attributes(aggregate)
          record_for_struct = aggregate.merge(attributes: record_attributes)

          f.puts Projector.emit_record(record_for_struct, value_objects_by_name)
          f.puts
          f.puts Projector.emit_to_json_flat(record_name, record_attributes, value_objects_by_name, optional: true, extra_fields: lifecycle_extra_field(aggregate) + Projector.corrects_extra_fields(aggregate), aggregate: aggregate)
          f.puts
          f.puts Projector.emit_from_json_state(record_name, record_attributes, value_objects_by_name, optional: true, extra_fields: lifecycle_extra_field(aggregate) + Projector.corrects_extra_fields(aggregate), aggregate: aggregate)
          f.puts
          # `dispatch`/`dispatch_entity` (kernel/dispatch.rs) are generic
          # over the record type and need `record.to_json()` to build a
          # `MutationRecord` — only possible through a trait bound, since
          # the inherent `to_json` just emitted above can't be called on a
          # bare generic `T`. Delegates straight to that inherent method
          # (Rust resolves the unqualified call inside this impl to the
          # inherent one, not back to itself — no recursion). Emitted only
          # for aggregate records, never value objects/entities/Args
          # structs: those are never the generic `T` in dispatch.rs.
          f.puts <<~RUST
            impl crate::kernel::ToJson for #{record_name} {
                fn to_json(&self) -> crate::kernel::Json {
                    #{record_name}::to_json(self)
                }
            }
          RUST
          f.puts
          f.puts Projector.emit_set_projected_field(aggregate)
          f.puts
          f.puts Projector.emit_projected_field_table(aggregate)
          f.puts
          acting_router_reason = "identity #{aggregate[:identified_by].inspect} isn't a shape extract_id resolves yet (json_codec.rb)"
          if can_route
            f.puts Projector.emit_extract_id(aggregate)
            f.puts
          else
            puts "skipping #{domain_name}::#{aggregate[:name]}'s JSON router acting-command entries: #{acting_router_reason}"
          end

          f.puts Projector.emit_invariants_fn(aggregate)
          f.puts

          aggregate[:commands].each do |command|
            command_verb = "#{domain_name}::#{aggregate[:name]}.#{command[:name]}"
            reason = Projector.command_skip_reason(command, aggregate, value_objects_by_name)
            if reason
              puts "skipping #{command_verb}: #{reason}"
              manifest << manifest_entry(kind: "command", id: command_verb, generated: false, gap_class: "per_instance", reason: reason)
              next
            end

            f.puts Projector.emit_command(command, aggregate, domain_name, value_objects_by_name, aggregates_by_name)
            f.puts
            args_struct = "#{Projector.rust_ident(command[:name])}Args"
            # to_json (not just from_json): an Event's payload is now
            # args.to_json() directly (commands.rb's own dispatch call) —
            # the SAME structural shape Ruby's `payload: args` already is,
            # and what a policy/process-manager reaction needs to forward
            # real data into a re-triggered command's own from_json.
            #
            # NOT `sparse: true` here — json_codec.rb's own `sparse:`
            # exists, is real, and closes a genuine gap (an unset
            # optional argument's key should be ABSENT from an emitted
            # event's payload, matching Ruby's `payload: args`, not
            # present-with-`null`) — but wiring it in here diverges this
            # generator's own output from `hecks-codegen`'s (a SEPARATE,
            # from-scratch Rust reimplementation `spec/codegen_parity_
            # spec.rb` holds byte-identical to this one), across nearly
            # every domain with any optional command attribute, not just
            # the one this was written for. A THIRD Rust effort, on top
            # of the parser gap `for_each` itself already found —
            # porting `sparse:` there too is real, separate work,
            # deliberately not attempted here. Left unwired so this
            # generator's own output stays exactly what it always was.
            f.puts Projector.emit_to_json_flat(args_struct, command[:attributes], value_objects_by_name, sparse: true)
            f.puts
            allowlist = Projector.command_argument_allowlist(aggregate, command, ir[:process_managers])
            f.puts Projector.emit_from_json_flat(args_struct, command[:attributes], value_objects_by_name, unknown_argument_allowlist: allowlist, command_name: command[:name].to_s, absent_argument_check: true, interleave_checks: true, aggregates_by_name: aggregates_by_name)
            f.puts

            # A CREATING command's identity comes from its own typed args
            # (build_identity_expr, already inside emit_command's output) —
            # routable regardless of extract_id, INCLUDING when that
            # expression needs an EXTRA function parameter
            # (identity_components' third shape — mutations.rb's own
            # `owner_id` example: an addressing key that is neither a
            # dotted path nor a declared command attribute). That
            # parameter's own JSON key is `head:` (mutations.rb, same
            # file) — a bare top-level field in `args_json` exactly the
            # way `id:`/a reference key already are for an ACTING
            # command's own `extract_id`, never part of the strongly-typed
            # `XArgs` struct (it was deliberately excluded from
            # `command[:attributes]`, per `refuse_unknown_arguments`'s own
            # allowlist) — so `registry.rb`'s router reads it off the SAME
            # raw JSON every other addressing key already comes from,
            # rather than needing a JSON step shape of its own.
            # An ACTING command's `id` comes from extract_id instead, so
            # it's routable only when THAT is (json_codec.rb's own gap).
            creates = Projector.creates_owner?(aggregate, command, value_objects_by_name)
            # `identity_components` is a CREATING command's own concern
            # only (mutations.rb's own header on `identity_components`:
            # "never called for an acting command") — an acting command's
            # `aggregate[:identified_by]` describes the SAME head's
            # identity, but that command reaches an EXISTING record via
            # `extract_id`/`id_line` below, not via minting one, so asking
            # for its own extra params here would name a JSON field
            # (`owner_id`) this command never actually needs supplied.
            identity_extra_params = creates ? Projector.identity_components(aggregate, command).filter_map { |c| c[:head] } : []

            unless creates || can_route
              # PREVIOUSLY SILENT: this branch used to fall through to the
              # loop's `next` (implicit, no `puts`, no record anywhere) —
              # every OTHER skip in this generator names itself; this one
              # didn't, purely because it long predates the manifest this
              # whole file now keeps. Naming it here doesn't change what
              # gets generated (the function above was already emitted;
              # only the registry entry that would route to it is
              # skipped, exactly as before) — it only makes a real,
              # per-instance, previously-invisible gap visible.
              puts "skipping #{command_verb}'s JSON router entry: #{acting_router_reason}"
              manifest << manifest_entry(kind: "command", id: command_verb, generated: true, routed: false,
                                          gap_class: "per_instance",
                                          reason: "generated as a real Rust function, but not JSON-dispatchable — #{acting_router_reason}")
              next
            end

            manifest << manifest_entry(kind: "command", id: command_verb, generated: true, routed: true)
            registry_commands << {
              verb: command_verb,
              name: command[:name],
              fn: Projector.dispatch_fn_name(Projector.rust_ident(command[:name])),
              args_struct: args_struct,
              creates: creates,
              identity_extra_params: identity_extra_params,
              # `state_reference_checks` — ADR 0037 Finding 5 (reopened,
              # QualityControl BUG#26): a reference field redeclared on
              # THIS command under a plain value object, checked against
              # the AGGREGATE's own `Reference<X>` attribute of the same
              # name instead of the command's own (non-reference) type.
              # Only ever adds entries `reference_checks` above didn't
              # already cover — see that method's own header.
              reference_checks: reference_checks(command, aggregates_by_name, unsupported_names) +
                state_reference_checks(aggregate, command, aggregates_by_name, unsupported_names, value_objects_by_name),
              reference_specs: Projector.reference_specs(domain_name, command[:attributes]),
              # THIS COMMAND'S OWN DECLARED ATTRIBUTE NAMES (R1) —
              # `reactions.rb`'s own `emit_command_attributes_table`
              # reads this, the SAME set `ReactionInvocation.command_facts`
              # (`args.slice(*declared)`) reads on the Ruby side.
              attributes: command[:attributes].map { |a| a[:name].to_s },
              role: command[:role],
              # R3 FIX (docs/audits/2026-08-11-bug-triage.md) — see the
              # identical field on `entity_commands`, above, for the full
              # reasoning: registry.rb's own router runs these BEFORE
              # `refuse_role_mismatch`/`resolve_references` now, matching
              # Ruby's `DISPATCH_ORDER` (VO invariant/admits/pattern is
              # enforced during `normalize_args`, which precedes both).
              invariant_check_lines: Projector.invariant_checks_for(command, aggregates_by_name, value_objects_by_name),
              # BUG#23 (qa/bluebook/quality_control.bluebook) — the SAME
              # `allowlist` this command's own `emit_from_json_flat` call
              # above already built, run through `Projector.structural_
              # precheck` so `registry.rb`'s router can run the identical
              # unknown/absent-argument gate a second time, standalone,
              # against raw `facts_json`, BEFORE `id_line` resolves —
              # see that method's own header for the full reasoning.
              # `nil` for a CREATING command: `id_line` is never emitted
              # for one (registry.rb's own `c[:creates] ? "" : ...`), so
              # there is no identity-resolution-before-structural-checks
              # race for this fix to close there.
              structural_precheck: creates ? nil : Projector.structural_precheck(args_struct, command[:name].to_s, command[:attributes], allowlist),
            }
          end

          # PORT OPERATIONS — the primary/driving half (rust/project/ports.rb's
          # own header): no Hydrate, no repo, so `can_route` never gates
          # these the way it gates an ACTING command's registry entry
          # above (there is no `extract_id`-derived `id` here at all — the
          # operation's own reference attribute already names the record,
          # exactly the same "resolved at the router level" reason a
          # command's own reference checks live in registry.rb and not here).
          aggregate[:ports].each do |port|
            port[:operations].each do |operation|
              operation_verb = "#{domain_name}::#{aggregate[:name]}.#{port[:name]}.#{operation[:name]}"
              reason = Projector.port_operation_skip_reason(operation, aggregate[:name], value_objects_by_name)
              if reason
                puts "skipping #{operation_verb}: #{reason}"
                manifest << manifest_entry(kind: "port_operation", id: operation_verb, generated: false,
                                            gap_class: "per_instance", reason: reason)
                next
              end

              f.puts Projector.emit_port_operation(operation, port[:name], aggregate[:name], domain_name, value_objects_by_name, aggregates_by_name)
              f.puts

              manifest << manifest_entry(kind: "port_operation", id: operation_verb, generated: true, routed: true)
              operation_args_struct = "#{Projector.rust_ident(port[:name])}#{Projector.rust_ident(operation[:name])}Args"
              # THE MIGRATION-ERA SELF-REFERENCE, if this operation still
              # declares one — `ports.rb#emit_port_operation` excludes it
              # from the generated args struct entirely (routing supplies
              # the receiver now), so a reference_check against it would
              # name a struct field that no longer exists; both filtered
              # out here, together, the same way `emit_port_operation`
              # and `registry.rb`'s own `split_aggregate_receiver` treat
              # this one field as a single unit.
              legacy_receiver_field = operation[:attributes]
                .find { |attr| Projector.reference_target(attr[:type]) == aggregate[:name] }
                &.dig(:name)
              # `to:`-DECLARED OPERATIONS — mirrors Dispatcher
              # #port_invocation's own second, additive branch
              # (lib/hecks/runtime/dispatcher.rb): no Reference-typed
              # attribute exists for these (legacy_receiver_field is
              # always nil), so the receiver instead comes from a plain
              # external-fact attribute named for the owning aggregate's
              # own identified_by field. A genuinely separate field, not
              # folded into legacy_receiver_field — registry.rb's own
              # split_aggregate_receiver call must NOT strip this one
              # out of the payload the way it strips a legacy receiver,
              # since it's a real declared fact, not routing-only
              # synthetic state (rust/src/kernel/routing.rs's own
              # split_aggregate_receiver already carries this exact
              # distinction, as a second parameter).
              # `.split(".").first` — the SAME "just the head" extraction
              # this file's own `heads` local already does elsewhere
              # (line ~96): `aggregate[:identified_by]` is `identity_
              # paths`, not the plain declared name (aggregate.rb's own
              # `emits_ir(identified_by: :identity_paths, ...)`) — for a
              # value-object-typed identity (Payment's own `identified_by
              # :reference` where `reference` is itself a Reference value
              # object), this resolves to the dotted internal path
              # "reference.value", not the flat "reference" the
              # operation's own plain attribute is actually named.
              # Confirmed the hard way: the first draft generated
              # `Some("reference.value")`, which `self.facts.get(...)`
              # (a flat lookup, no nested-path traversal) would never
              # find against a real `{"reference": "..."}` payload.
              to_receiver_field = operation[:to] == aggregate[:name] ? aggregate[:identified_by]&.first&.split(".")&.first : nil
              operation_reference_checks = reference_checks(operation, aggregates_by_name, unsupported_names)
                .reject { |check| check[:target_name] == aggregate[:name] }
              port_operations << {
                verb: operation_verb,
                name: operation[:name],
                fn: "#{port[:name].downcase}_#{Projector.dispatch_fn_name(Projector.rust_ident(operation[:name]))}",
                args_struct: operation_args_struct,
                reference_checks: operation_reference_checks,
                legacy_receiver_field: legacy_receiver_field,
                to_receiver_field: to_receiver_field,
              }
            end
          end
        end
        puts(wrote ? "wrote #{path}" : "#{path} unchanged")

        registry_aggregates << {
          name: aggregate[:name],
          mod: aggregate[:name].downcase,
          record: record_name,
          commands: registry_commands,
          entity_commands: entity_commands,
          nested_entity_commands: nested_entity_commands,
          ports: port_operations,
          # THIS AGGREGATE'S OWN DECLARED IDENTITY PATHS, carried through
          # verbatim — `emit_identity_head_table`/`reactions.rb` reads the
          # single-component case (the only shape it resolves; a
          # composite identity is a real, documented gap there, not
          # silently assumed to work).
          identified_by: aggregate[:identified_by],
          # THIS AGGREGATE'S OWN NESTED ENTITIES, name + identity paths
          # only — `emit_entity_identity_head_table`/`reactions.rb`'s own
          # sibling to `identified_by` just above, one level down
          # (BUG#10: a saga-dispatched entity command needs the ENTITY's
          # own identity, not just its parent aggregate's).
          entities: aggregate[:entities].map { |e| { name: e[:name], identified_by: e[:identified_by] } },
          # WHICH TOP-LEVEL GENERATED MODULE this aggregate's own .rs file
          # lives under (`meta`, `embryonaut`, `governance`, ...) — a
          # standalone per-chapter registry.rs (this file, below) uses it
          # to qualify every cross-file path as `crate::generated::
          # #{chapter_mod}::...` instead of the old bare `super::...`
          # (only valid within THIS module's own directory); bin/project_
          # rust's separate MERGED registry (spanning every chapter a
          # domain attaches) relies on the SAME field to tell aggregates
          # from different chapters apart once they're combined into one
          # list.
          chapter_mod: mod_name,
          # `reference_specs` — this AGGREGATE's own declared `reference_to`/
          # `belongs_to` attributes (`Reference<X>`), for the domain-wide
          # `REFERENCE_TABLE` `registry.rb`'s own `emit_reference_lookup`
          # builds AND for an acting command's own `owner_deref` fetch
          # (registry.rb's `aggregate_arms`/`entity_arms`, both keyed off
          # this SAME aggregate hash) — computed once here, off the real
          # IR `attributes` list, not re-derived per command.
          reference_specs: Projector.reference_specs(domain_name, aggregate[:attributes]),
          # The bluebook's own DECLARED name ("Governance", not the
          # lowercase module "governance") — `emit_registry`'s own
          # `Store#instances()` dump uses this PER-aggregate, not a
          # single shared name, precisely so a merged multi-chapter
          # registry labels each record "Governance::RoleAssignment#..."
          # /"Embryonaut::Member#..." correctly rather than mislabeling
          # every aggregate with whichever chapter happened to be passed
          # in as this call's own top-level domain_name.
          domain_name: domain_name,
        }
      end

      # ── QUERIES — a declared `query "X" do ... end` block now generates
      # for real, for the subset `queries.rb`'s own `query_skip_reason`
      # admits (one or more field-comparator conditions, ANDed, against a
      # single aggregate's OWN attributes, PLUS — as of 2026-08-11 — that
      # same result set's own `order_by`/`limit`, PLUS — as of Phase 10,
      # equivalence-gap plan — its own `offset` and a declared `nulls`
      # override too; still no hop/type-unrecoverable literal/cursor/
      # consistency/freshness/inspection/use_index). A "per_instance"
      # gap now, not "whole_kind" — the CONSTRUCT KIND has a real code path;
      # a specific declared query still lacking a row is a per-instance
      # shape this generator doesn't cover, the same distinction every
      # OTHER per-instance skip in this file already draws.
      ir[:aggregates].each do |aggregate|
        value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }

        aggregate[:queries].each do |query|
          query_verb = "#{domain_name}::#{aggregate[:name]}.#{query[:name]}"
          reason = Projector.query_skip_reason(query, aggregate, value_objects_by_name)
          if reason
            puts "skipping query #{query_verb}: #{reason}"
            manifest << manifest_entry(kind: "query", id: query_verb, generated: false, gap_class: "per_instance", reason: reason)
            next
          end

          manifest << manifest_entry(kind: "query", id: query_verb, generated: true)
          query_defs << {
            verb: query_verb,
            aggregate: "#{domain_name}::#{aggregate[:name]}",
            arg_checks: Projector.query_arg_checks(query, "crate::generated::#{mod_name}::#{aggregate[:name].downcase}",
                                                   value_objects_by_name),
            conditions: Projector.query_conditions_with_authorization(query),
            order_by: query[:order_by] ? Projector.emit_query_order_by(query[:order_by], query[:null_semantics]) : nil,
            offset: query[:offset] ? Projector.emit_query_offset(query[:offset]) : nil,
            limit: query[:limit] ? Projector.emit_query_limit(query[:limit]) : nil,
            authorization: Projector.emit_query_authorization(query[:name], query[:authorization]),
          }
        end
      end

      # ── READ MODELS — a declared `report "X" do ... end` block
      # (`ReadModel`, the `read_model` construct) now generates for
      # real, for the subset `read_models.rb`'s own `read_model_skip_
      # reason` admits (a root aggregate fetched by reference id, plus
      # reference-matched sibling heads — no where/order_by/limit/etc,
      # see that file's own header for the full argument, including why
      # where/order_by/limit specifically are a STRUCTURAL gap in the
      # canonical IR this generator reads, not merely unported). A
      # "per_instance" gap now, not "whole_kind" — the CONSTRUCT KIND has
      # a real code path; a specific declared read model still lacking a
      # row is a per-instance shape this generator doesn't cover, the
      # same distinction the query codegen above already draws for
      # itself.
      read_model_defs = []
      ir[:read_models].each do |read_model|
        read_model_id = "#{domain_name}::#{read_model[:name]}"
        reason = Projector.read_model_skip_reason(read_model, aggregates_by_name, unsupported_names)
        if reason
          puts "skipping read_model #{read_model_id}: #{reason}"
          manifest << manifest_entry(kind: "read_model", id: read_model_id, generated: false, gap_class: "per_instance", reason: reason)
          next
        end

        manifest << manifest_entry(kind: "read_model", id: read_model_id, generated: true)
        read_model_defs << Projector.read_model_def(domain_name, read_model, aggregates_by_name)
      end

      # ── POLICIES — a same-domain policy generates into `POLICIES`
      # (`local_policy_rows`) and dispatches locally; a cross-domain
      # policy (`across:` naming a domain this `bin/project_rust` run
      # didn't also compile into this one `Store`) generates into the
      # SEPARATE `CROSS_DOMAIN_POLICIES` table (`emit_cross_domain_policy_
      # table`) instead — matched by `kernel::orchestrate` the identical
      # way, recorded as a `PendingCrossDomainReaction` in `kernel::cli::
      # run`'s own JSON output, and delivered by rust/host's
      # `lambda_client.rs` (a port of `Adapters::Lambda::Client`) rather
      # than a local `dispatch_by_name` call. Both are genuinely
      # generated and reachable through kernel/cli.rs's JSON router now —
      # what this manifest entry CANNOT attest to is whether the target
      # Lambda a live cross-domain reaction names actually exists and
      # accepts the call; that's an operational fact about a real
      # deploy, not a codegen fact this generator could ever check.
      # `rust/host/src/lambda_client.rs`'s own header states plainly what
      # is unit/mock-tested here versus what remains structurally-argued
      # pending live AWS infrastructure.
      ir[:policies].each do |policy|
        manifest << manifest_entry(kind: "policy", id: "#{domain_name}::#{policy[:name]}", generated: true, routed: true)
      end

      # ── PROCESS MANAGERS / SAGAS — `emit_process_manager_table`
      # (reactions.rb) has no per-instance skip condition anywhere in
      # its own body, unlike `emit_policy_table` above: every declared
      # process manager's own `dispatch` targets are already fully
      # domain-qualified on the wire, so nothing here can name a target
      # outside this compile the way a policy's own `across:` can.
      # Verified against this method's own reading of reactions.rb, not
      # assumed — if that ever grows a skip condition, this loop is the
      # one place that needs updating to match it.
      ir[:process_managers].each do |pm|
        manifest << manifest_entry(kind: "process_manager", id: "#{domain_name}::#{pm[:name]}", generated: true, routed: true)
      end

      # ── LINEAGE-CAPABLE AGGREGATES — `ir[:lineage][:capable_aggregates]`
      # (Exporter.lineage's own binding-fact list, merged into `ir` by
      # bin/project_rust before it ever reaches this method) rather than
      # a fresh `[:aggregates]` scan: which adapter an aggregate is bound
      # to is a DEPLOYMENT fact, not something this generator re-derives
      # from the bluebook's own shape. `generated: true` unconditionally
      # — unlike every OTHER manifest entry above, there is no per-
      # instance skip condition to check here, because rust/host's own
      # read/write path (journal::read_lineage_head_all/_by_id,
      # journal::append_lineage_mutation) is GENERIC over `storage_name`:
      # it already works for any aggregate this list ever names, the
      # same way it was proven for `Embryonaut::Member` before this
      # generalized it. `routed: true` for the same reason: reachable
      # the moment a caller has `storage_name`, not gated behind a
      # kernel/cli.rs match arm the way a WASM-dispatched command is —
      # see rust/project.rb's own header on why this is a HOST-level
      # capability, deliberately never routed through the WASM kernel at
      # all.
      ir.fetch(:lineage, {}).fetch(:capable_aggregates, []).each do |aggregate|
        manifest << manifest_entry(
          kind: "lineage_aggregate", id: "#{domain_name}::#{aggregate[:name]}", generated: true, routed: true,
          reason: "read via rust/host's journal::read_lineage_head_all/_by_id, written via journal::" \
                  "append_lineage_mutation — both generic over storage_name (\"#{aggregate[:storage_name]}\"), " \
                  "dispatched OUTSIDE the WASM kernel/InMemoryRepository path entirely, matching Ruby's own " \
                  "CommandInterpreter routing for a Postgres-bound aggregate (rust/project.rb's own header)"
        )
      end

      metadata_path = File.join(mod_dir, "metadata.rs")
      wrote = WriteIfChanged.block(metadata_path) do |f|
        f.puts "// GENERATED by bin/project_rust — #{source_label}'s own canonical IR,"
        f.puts "// embedded for runtime self-description. Not read by any dispatch"
        f.puts "// function in this module — introspection only."
        f.puts "pub const IR_JSON: &str = #{Projector.rust_string_literal(JSON.pretty_generate(ir))};"
      end
      puts(wrote ? "wrote #{metadata_path}" : "#{metadata_path} unchanged")

      # SAME `ir`, as a plain file — rust/host deliberately carries no
      # path dependency on this crate (its own Cargo.toml: the .wasm
      # module is an opaque, untrusted artifact loaded through wasmtime
      # at runtime, never linked in as Rust source), so metadata.rs's
      # own IR_JSON constant is unreachable from rust/host at compile
      # time. bin/project_wasm copies this sidecar into rust/dist/
      # beside the .wasm artifact, the same way it already copies that
      # artifact itself, so a Rust-native web layer (rust/host/src/web.rs)
      # can read it at runtime via HECKS_IR_PATH.
      ir_json_path = File.join(mod_dir, "ir.json")
      wrote = WriteIfChanged.call(ir_json_path, JSON.pretty_generate(ir))
      puts(wrote ? "wrote #{ir_json_path}" : "#{ir_json_path} unchanged")

      # THE COVERAGE MANIFEST, alongside `ir.json` for the same reason
      # `ir.json` sits alongside `metadata.rs` — one is this call's own
      # account of what it read, the other is this call's own account of
      # what it DID with what it read. `bin/rust_coverage` reads both and
      # diffs them against an allowlist; nothing in this generator reads
      # `manifest.json` back — same "written for an external reader,
      # never consulted internally" contract `metadata.rs`'s own header
      # already states for `IR_JSON`.
      manifest_path = File.join(mod_dir, "manifest.json")
      wrote = WriteIfChanged.call(manifest_path, JSON.pretty_generate(manifest))
      puts(wrote ? "wrote #{manifest_path}" : "#{manifest_path} unchanged")

      registry_path = File.join(mod_dir, "registry.rs")
      wrote_registry = WriteIfChanged.block(registry_path) do |f|
        f.puts Projector.emit_registry(registry_aggregates)
        f.puts
        f.puts Projector.emit_reference_lookup(registry_aggregates)
        f.puts
        f.puts Projector.emit_policy_table(domain_name, ir[:policies], ir[:aggregates])
        f.puts
        f.puts Projector.emit_cross_domain_policy_table(domain_name, ir[:policies])
        f.puts
        f.puts Projector.emit_process_manager_table(ir[:process_managers])
        f.puts
        f.puts Projector.emit_reference_key_table([[domain_name, generated_aggregates.map { |a| a[:name] }]])
        f.puts
        f.puts Projector.emit_creates_table(registry_aggregates)
        f.puts
        f.puts Projector.emit_identity_head_table(registry_aggregates)
        f.puts
        f.puts Projector.emit_entity_identity_head_table(registry_aggregates)
        f.puts
        f.puts Projector.emit_command_attributes_table(registry_aggregates)
        f.puts
        f.puts Projector.emit_query_table(query_defs)
        f.puts
        f.puts Projector.emit_query_arg_check_table(query_defs)
        f.puts
        read_model_defs.each do |rmd|
          next unless rmd[:group_by_fn_body]

          f.puts rmd[:group_by_fn_body]
          f.puts
        end
        f.puts Projector.emit_read_model_table(read_model_defs)
      end
      puts(wrote_registry ? "wrote #{registry_path}" : "#{registry_path} unchanged")

      mod_path = File.join(mod_dir, "mod.rs")
      # PRESERVE AN ALREADY-PRESENT "pub mod merged;" TRAILER — this
      # generator itself never writes that line (bin/project_rust
      # appends it separately, only for a domain/chapter that later
      # gets its own merged.rs; framework chapters like governance never
      # do). Without this, comparing this run's base-only content
      # against last run's base-PLUS-merged content on disk would look
      # "changed" every single time regardless of whether anything real
      # changed, defeating WriteIfChanged.block's whole purpose here —
      # confirmed live: measured zero speedup on a second, content-
      # identical wasm build until this was fixed. Re-including the
      # trailer (when it was already there) makes the comparison
      # apples-to-apples; bin/project_rust's own append-if-missing check
      # below still handles the first time a domain ever gets one.
      merged_trailer = File.exist?(mod_path) && File.read(mod_path).include?("pub mod merged;")
      wrote_mod = WriteIfChanged.block(mod_path) do |f|
        f.puts "// GENERATED by bin/project_rust — re-run it to refresh this list."
        f.puts "pub mod metadata;"
        f.puts "pub mod registry;"
        generated_aggregates.each { |a| f.puts "pub mod #{a[:name].downcase};" }
        f.puts "pub mod merged;" if merged_trailer
      end
      puts(wrote_mod ? "wrote #{mod_path}" : "#{mod_path} unchanged")

      # RETURNED, not just written — bin/project_rust concatenates
      # `:aggregates` across every chapter a domain attaches
      # (`uses_framework`) to emit ONE merged Store/dispatch_by_name
      # spanning all of them (a real, separate step; see bin/project_rust's
      # own comment), and `:queries` the same way, for the merged QUERIES
      # table alongside it. Each aggregate entry already carries its own
      # `chapter_mod:` (set above), so the merged registry emitter can
      # qualify cross-chapter paths correctly with no further tagging
      # needed here; a query_def carries no chapter tag at all because it
      # never needs one — `verb`/`aggregate` are already fully
      # domain-qualified strings, exactly like a command's own `verb`.
      # `read_models` rides alongside for the identical reason: a
      # `read_model_def`'s own `verb`/`heads` are already fully
      # domain-qualified too.
      { aggregates: registry_aggregates, queries: query_defs, read_models: read_model_defs }
    end
  end
end

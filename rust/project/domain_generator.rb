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
    # unsupported attribute type, a `then_set` shape this generator's
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

      ir[:aggregates].each do |aggregate|
        value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }
        # BEFORE anything below reads a single `attr[:optional]` off an
        # entity/value-object field — every one of those reads (the
        # struct-field wrap two loops down, `command_skip_reason`'s own
        # optional-source check) needs to see the derived fact, not just
        # whatever the domain author wrote by hand (mutations.rb's own
        # header on why this is safe to run unconditionally, every time).
        Projector.mark_append_optional_fields!(aggregate, value_objects_by_name)

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
        port_operations = []
        record_name = Projector.rust_ident(aggregate[:name])

        path = File.join(mod_dir, "#{aggregate[:name].downcase}.rs")
        File.open(path, "w") do |f|
          f.puts "// GENERATED by bin/project_rust from #{source_label}'s canonical IR."
          f.puts "// Do not hand-edit — re-run bin/project_rust instead."
          f.puts "#![allow(dead_code, unused_variables)]"
          f.puts 'use crate::kernel::Expr;'
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

            entity_can_route = Projector.extract_id_supported?(entity)
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

              f.puts Projector.emit_entity_command(command, entity, aggregate, domain_name, value_objects_by_name, aggregates_by_name)
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
                args_struct: "#{entity_name}#{Projector.rust_ident(command[:name])}Args",
                reference_checks: reference_checks(command, aggregates_by_name, unsupported_names),
                role: command[:role],
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

          f.puts Projector.emit_record(aggregate, value_objects_by_name)
          f.puts
          f.puts Projector.emit_to_json_flat(record_name, aggregate[:attributes], value_objects_by_name, optional: true, extra_fields: lifecycle_extra_field(aggregate), aggregate: aggregate)
          f.puts
          f.puts Projector.emit_from_json_state(record_name, aggregate[:attributes], value_objects_by_name, optional: true, extra_fields: lifecycle_extra_field(aggregate), aggregate: aggregate)
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
          acting_router_reason = "identity #{aggregate[:identified_by].inspect} isn't a shape extract_id resolves yet (json_codec.rb)"
          if can_route
            f.puts Projector.emit_extract_id(aggregate)
            f.puts
          else
            puts "skipping #{domain_name}::#{aggregate[:name]}'s JSON router acting-command entries: #{acting_router_reason}"
          end

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
            f.puts Projector.emit_to_json_flat(args_struct, command[:attributes], value_objects_by_name)
            f.puts
            allowlist = Projector.command_argument_allowlist(aggregate, command, ir[:process_managers])
            f.puts Projector.emit_from_json_flat(args_struct, command[:attributes], value_objects_by_name, unknown_argument_allowlist: allowlist, command_name: command[:name].to_s)
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
            creates = command[:references].nil?
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
              reference_checks: reference_checks(command, aggregates_by_name, unsupported_names),
              role: command[:role],
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
              port_operations << {
                verb: operation_verb,
                name: operation[:name],
                fn: "#{port[:name].downcase}_#{Projector.dispatch_fn_name(Projector.rust_ident(operation[:name]))}",
                args_struct: operation_args_struct,
                reference_checks: reference_checks(operation, aggregates_by_name, unsupported_names),
              }
            end
          end
        end
        puts "wrote #{path}"

        registry_aggregates << {
          name: aggregate[:name],
          mod: aggregate[:name].downcase,
          record: record_name,
          commands: registry_commands,
          entity_commands: entity_commands,
          ports: port_operations,
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
      # same result set's own `order_by`/`limit`; still no hop/type-
      # unrecoverable literal/offset/cursor/consistency/freshness/
      # authorization/null_semantics/inspection/use_index). A "per_instance"
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
            conditions: Projector.query_conditions(query),
            order_by: query[:order_by] ? Projector.emit_query_order_by(query[:order_by]) : nil,
            limit: query[:limit] ? Projector.emit_query_limit(query[:limit]) : nil,
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
      File.open(metadata_path, "w") do |f|
        f.puts "// GENERATED by bin/project_rust — #{source_label}'s own canonical IR,"
        f.puts "// embedded for runtime self-description. Not read by any dispatch"
        f.puts "// function in this module — introspection only."
        f.puts "pub const IR_JSON: &str = #{JSON.pretty_generate(ir).inspect};"
      end
      puts "wrote #{metadata_path}"

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
      File.write(ir_json_path, JSON.pretty_generate(ir))
      puts "wrote #{ir_json_path}"

      # THE COVERAGE MANIFEST, alongside `ir.json` for the same reason
      # `ir.json` sits alongside `metadata.rs` — one is this call's own
      # account of what it read, the other is this call's own account of
      # what it DID with what it read. `bin/rust_coverage` reads both and
      # diffs them against an allowlist; nothing in this generator reads
      # `manifest.json` back — same "written for an external reader,
      # never consulted internally" contract `metadata.rs`'s own header
      # already states for `IR_JSON`.
      manifest_path = File.join(mod_dir, "manifest.json")
      File.write(manifest_path, JSON.pretty_generate(manifest))
      puts "wrote #{manifest_path}"

      registry_path = File.join(mod_dir, "registry.rs")
      File.open(registry_path, "w") do |f|
        f.puts Projector.emit_registry(registry_aggregates)
        f.puts
        f.puts Projector.emit_policy_table(domain_name, ir[:policies])
        f.puts
        f.puts Projector.emit_cross_domain_policy_table(domain_name, ir[:policies])
        f.puts
        f.puts Projector.emit_process_manager_table(ir[:process_managers])
        f.puts
        f.puts Projector.emit_reference_key_table([[domain_name, generated_aggregates.map { |a| a[:name] }]])
        f.puts
        f.puts Projector.emit_query_table(query_defs)
        f.puts
        f.puts Projector.emit_read_model_table(read_model_defs)
      end
      puts "wrote #{registry_path}"

      mod_path = File.join(mod_dir, "mod.rs")
      File.open(mod_path, "w") do |f|
        f.puts "// GENERATED by bin/project_rust — re-run it to refresh this list."
        f.puts "pub mod metadata;"
        f.puts "pub mod registry;"
        generated_aggregates.each { |a| f.puts "pub mod #{a[:name].downcase};" }
      end
      puts "wrote #{mod_path}"

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

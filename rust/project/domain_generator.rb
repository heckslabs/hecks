require "fileutils"
require "json"

module RustProjection
  # Generates one domain's worth of Rust types, Fielded impls and commands into
  # `mod_dir`, plus `metadata.rs` (embedded IR JSON for runtime introspection) and
  # `registry.rs` (the JSON command router `kernel::cli.rs` dispatches through).
  module DomainGenerator
    module_function

    # One manifest row per generate/skip decision, written to manifest.json
    # alongside ir.json so hecks rust_coverage never has to re-derive "did this
    # generate?" by grepping generated Rust source.
    #
    # gap_class distinguishes a "whole_kind" gap (this construct kind has no
    # code path here at all, for any domain) from a "per_instance" one (the
    # kind generates in general, but this declared instance failed one of
    # this generator's own per-instance checks). construct names the family
    # that forced a gap; gap_class and construct must travel together, since
    # downstream readers (the differential fuzzer, hecks rust_coverage's
    # allowlist) match gaps by these fields, never by reason prose.
    def manifest_entry(kind:, id:, generated:, reason: nil, gap_class: nil, routed: nil, construct: nil)
      if (generated == false || routed == false) && gap_class.nil?
        raise ArgumentError, "manifest entry #{kind} #{id} records a gap with no gap_class"
      end
      if gap_class && construct.to_s.empty?
        raise ArgumentError, "manifest entry #{kind} #{id} declares gap_class #{gap_class.inspect} with no construct — " \
                             "every recorded gap names the construct family that forced it"
      end

      entry = { kind: kind, id: id, generated: generated }
      entry[:routed] = routed unless routed.nil?
      entry[:gap_class] = gap_class if gap_class
      entry[:construct] = construct.to_s if gap_class
      entry[:reason] = reason.to_s if reason
      entry
    end

    # Entity-scoped queries have no generated code path (the query loop in
    # `call` walks aggregate[:queries] only). Recorded here as the
    # whole-kind gap they are, recursively, one entry per declared entity
    # query at any depth.
    def entity_query_entries(owner_id, entities)
      entities.flat_map do |entity|
        entity_id = "#{owner_id}.#{entity[:name]}"
        own = Array(entity[:queries]).map do |query|
          manifest_entry(kind: "query", id: "#{entity_id}.#{query[:name]}", generated: false, gap_class: "whole_kind",
                         construct: "entity_query",
                         reason: "an entity-scoped query has no generated code path — only an aggregate's own " \
                                 "declared queries reach the QUERIES table")
        end
        own + entity_query_entries(entity_id, Array(entity[:entities]))
      end
    end

    def lifecycle_extra_field(node)
      return [] unless node[:lifecycle]

      field = Projector.rust_ident_field(node[:lifecycle][:field])
      [[Projector.rust_field(node[:lifecycle][:field]), "crate::kernel::Json::Str(self.#{field}.clone())"]]
    end

    # For each Reference<X> command attribute, resolves X against every
    # aggregate this domain declares, not just the ones already written
    # when this command's file is reached — matching Ruby's lazy
    # attribute-type resolution, which already allows forward references
    # across aggregates in one file.
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

    # Catches a reference field redeclared on the command under a plain
    # value object (the attribute isn't reference?-true, so reference_checks
    # above finds nothing to check) by checking against the aggregate's own
    # Reference<X> field of the same name instead. Reuses the same
    # pre-dispatch, args-based check shape as reference_checks, since a bare
    # `sets :field` mutation (no `to:`, `append:`, etc.) copies its source
    # argument straight into the settled state, so the value is already in
    # `args` before dispatch runs (ADR 0037). Only covers a bare :set
    # mutation on a scalar or single-attribute value object; a `has_many`
    # relationship and entity-level recursion are left unchecked.
    def state_reference_checks(aggregate, command, aggregates_by_name, unsupported_names, value_objects_by_name)
      aggregate[:attributes].filter_map do |attr|
        target_name = Projector.reference_target(attr[:type])
        next unless target_name

        mutation = command[:mutations].find do |m|
          m[:op].to_s == "set" && m[:target].to_s == attr[:name].to_s && m[:source][:kind] == "argument"
        end
        next unless mutation

        source_attr = command[:attributes].find { |a| a[:name].to_s == mutation[:source][:name].to_s }
        next unless source_attr
        next if Projector.reference_target(source_attr[:type])

        # A has_many field needs one check_reference per element
        # (reference_check_list) rather than the scalar accessor, since
        # dotting `.value` into the whole Vec wouldn't compile.
        list_item = nil
        if attr[:list]
          list_item = list_reference_check_item(source_attr, value_objects_by_name)
          next unless list_item

          accessor = source_attr[:name]
        else
          accessor = state_reference_check_accessor(source_attr, value_objects_by_name)
          next unless accessor
        end

        target = aggregates_by_name[target_name]
        next unless target
        next if unsupported_names.include?(target_name)

        {
          field: accessor,
          optional: source_attr[:optional],
          list_item: list_item,
          target_mod: target[:name].downcase,
          target_name: target[:name],
          heads: target[:identified_by].map { |path| path.split(".").first }.join(", "),
        }
      end
    end

    # The per-element key expression reference_check_list checks: bare
    # `item` for a list_of(String), or `&item.<field>` for a list of
    # single-String-attribute value objects. nil for any other element
    # shape — left unchecked, same as state_reference_check_accessor's own
    # gaps.
    def list_reference_check_item(source_attr, value_objects_by_name)
      return nil unless source_attr[:list]
      return "item" if source_attr[:type].to_s == "String"

      vo = value_objects_by_name[source_attr[:type]]
      return nil unless vo && vo[:attributes].size == 1
      return nil unless vo[:attributes].first[:type].to_s == "String"

      "&item.#{Projector.rust_ident_field(vo[:attributes].first[:name])}"
    end

    # The source argument's own field-access expression, tacked onto
    # `args.` by emit_reference_check. A plain scalar argument needs no
    # accessor (nil means "use the field name as-is"). A single-attribute
    # value object needs `.field` appended, but only for a required
    # argument — check_reference's optional template assumes
    # Option<String>, not Option<Struct>. A multi-attribute value object
    # has no single field to dot into. nil for both: a deliberately narrow
    # gap the real corpus doesn't exercise.
    def state_reference_check_accessor(source_attr, value_objects_by_name)
      return source_attr[:name] if Projector.effective_scalar_type(source_attr[:type])

      vo = value_objects_by_name[source_attr[:type]]
      return nil unless vo
      return nil if source_attr[:optional]
      return nil unless vo[:attributes].size == 1

      "#{source_attr[:name]}.#{Projector.rust_ident_field(vo[:attributes].first[:name])}"
    end

    # An aggregate's tenant field is whichever field one of its own queries
    # names via `authorize policy, tenant: :field` — reused here to name a
    # field on the aggregate itself for the write side. nil when no query
    # declares one.
    def tenant_field_for(aggregate)
      query = Array(aggregate[:queries]).find { |q| q[:authorization] && q[:authorization][:tenant] }
      query && query[:authorization][:tenant]
    end

    # The write-side mirror of the query-side tenant boundary (ADR 0037):
    # reuses the same pre-dispatch, args-based check shape as
    # reference_checks/state_reference_checks above, since a bare `sets
    # :field` mutation copies its source argument straight into settled
    # state before dispatch runs. Fires only when both sides declare a
    # tenant field and it's reachable off this command's args in the same
    # narrow accessor shape state_reference_check_accessor already
    # establishes; every other case bails to `[]`, never raises.
    def tenant_boundary_checks(aggregate, command, aggregates_by_name, unsupported_names, value_objects_by_name)
      own_tenant_field = tenant_field_for(aggregate)
      return [] unless own_tenant_field

      own_tenant_attr = command[:attributes].find { |a| a[:name].to_s == own_tenant_field.to_s }
      return [] unless own_tenant_attr

      own_accessor = state_reference_check_accessor(own_tenant_attr, value_objects_by_name)
      return [] unless own_accessor

      command[:attributes].filter_map do |attr|
        target_name = Projector.reference_target(attr[:type])
        next unless target_name

        target = aggregates_by_name[target_name]
        next unless target
        next if unsupported_names.include?(target_name)

        target_tenant_field = tenant_field_for(target)
        next unless target_tenant_field

        target_tenant_attr = target[:attributes].find { |a| a[:name].to_s == target_tenant_field.to_s }
        next unless target_tenant_attr

        target_accessor = state_reference_check_accessor(target_tenant_attr, value_objects_by_name)
        next unless target_accessor

        {
          reference_field: attr[:name],
          target_mod: target[:name].downcase,
          target_name: target[:name],
          aggregate_name: aggregate[:name],
          own_tenant_field: own_tenant_field,
          own_accessor: own_accessor,
          target_tenant_field: target_tenant_field,
          target_accessor: target_accessor,
        }
      end
    end

    # Writes one chapter's generated Rust (per-aggregate files, registry.rs,
    # metadata.rs, mod.rs) into mod_dir, and returns its aggregates, queries
    # and read_models so a multi-chapter caller can merge them.
    def call(ir, source_label, mod_dir, mod_name, merged_module: true)
      # Validated before any side effects (mkdir_p included) so every name
      # collision in one domain is reported at once, rather than after some
      # aggregates already had files written.
      refusal = Projector.reserved_name_refusal(source_label, mod_name, ir[:aggregates].map { |a| a[:name] })
      raise refusal if refusal

      unsafe = Projector.unsafe_name_refusal(source_label, ir)
      raise unsafe if unsafe

      FileUtils.mkdir_p(mod_dir)
      domain_name = ir[:name]
      generated_aggregates = []
      registry_aggregates = []
      # See manifest_entry's own header. Written to manifest.json at the
      # end of this method, alongside the ir.json sidecar.
      manifest = []
      # Accumulated the same way registry_aggregates is, and returned so a
      # multi-chapter caller can union query defs across chapters too.
      query_defs = []
      aggregates_by_name = ir[:aggregates].to_h { |a| [a[:name], a] }
      unsupported_names = ir[:aggregates].select do |a|
        vo_by_name = a[:value_objects].to_h { |vo| [vo[:name], vo] }
        Projector.unsupported_attribute_types(a, vo_by_name).any?
      end.map { |a| a[:name] }
      # A command attribute can reference any value object the domain
      # declares, not just one its own aggregate also declares.
      # cross_aggregate_vo_imports uses this map to emit the `use` line
      # that makes the identifier resolve; codegen call sites still emit
      # the same bare type name.
      domain_value_object_owner = ir[:aggregates].each_with_object({}) do |a, index|
        a[:value_objects].each { |vo| index[vo[:name]] = a[:name] }
      end
      # Same domain-wide reach as above: bridging a cross-aggregate command
      # argument's type into its target field needs the actual definition,
      # not just which aggregate owns it. Merged into each aggregate's own
      # local map below, with the local map winning any name collision.
      domain_value_objects_by_name = ir[:aggregates].flat_map { |a| a[:value_objects] }.to_h { |vo| [vo[:name], vo] }
      ir[:aggregates].each do |aggregate|
        value_objects_by_name = domain_value_objects_by_name.merge(aggregate[:value_objects].to_h { |vo| [vo[:name], vo] })
        # Must run before anything below reads attr[:optional] on an
        # entity/value-object field, since those reads need the derived
        # fact, not just what the domain author wrote by hand.
        Projector.mark_append_optional_fields!(aggregate, value_objects_by_name)
        Projector.derive_reverses_mutations!(aggregate)

        unsupported = Projector.unsupported_attribute_types(aggregate, value_objects_by_name)
        if unsupported.any?
          aggregate_reason = "attribute type(s) #{unsupported.join(', ')} not generated yet " \
                              "(a bare, non-list entity-typed attribute isn't resolved to a Rust type)"
          puts "skipping #{domain_name}::#{aggregate[:name]}: #{aggregate_reason}"
          manifest << manifest_entry(kind: "aggregate", id: "#{domain_name}::#{aggregate[:name]}", generated: false,
                                      gap_class: "per_instance", construct: "attribute_type", reason: aggregate_reason)
          # Every command/entity/port-op this aggregate owns is recorded
          # too, tracing back to the same root cause, rather than silently
          # vanishing from the manifest with the aggregate.
          aggregate[:commands].each do |command|
            manifest << manifest_entry(kind: "command", id: "#{domain_name}::#{aggregate[:name]}.#{command[:name]}",
                                        generated: false, gap_class: "per_instance",
                                        construct: "owning_aggregate", reason: "owning aggregate not generated: #{aggregate_reason}")
          end
          aggregate[:entities].each do |entity|
            manifest << manifest_entry(kind: "entity", id: "#{domain_name}::#{aggregate[:name]}.#{entity[:name]}",
                                        generated: false, gap_class: "per_instance",
                                        construct: "owning_aggregate", reason: "owning aggregate not generated: #{aggregate_reason}")
            entity[:commands].each do |command|
              manifest << manifest_entry(kind: "entity_command",
                                          id: "#{domain_name}::#{aggregate[:name]}.#{entity[:name]}.#{command[:name]}",
                                          generated: false, gap_class: "per_instance",
                                          construct: "owning_aggregate", reason: "owning aggregate not generated: #{aggregate_reason}")
            end
          end
          aggregate[:ports].each do |port|
            port[:operations].each do |operation|
              manifest << manifest_entry(kind: "port_operation",
                                          id: "#{domain_name}::#{aggregate[:name]}.#{port[:name]}.#{operation[:name]}",
                                          generated: false, gap_class: "per_instance",
                                          construct: "owning_aggregate", reason: "owning aggregate not generated: #{aggregate_reason}")
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
          f.puts "// GENERATED by hecks project_rust from #{source_label}'s canonical IR."
          f.puts "// Do not hand-edit — re-run hecks project_rust instead."
          f.puts "#![allow(dead_code, unused_variables)]"
          f.puts 'use crate::kernel::Expr;'
          Projector.cross_aggregate_vo_imports(aggregate, domain_value_object_owner, mod_name).each { |line| f.puts line }
          f.puts

          aggregate[:value_objects].each do |vo|
            f.puts Projector.emit_value_object(vo, value_objects_by_name, aggregates_by_name)
            f.puts
            if vo[:closed_set] && vo[:attributes].size == 1
              # A single-field closed set collapses to a Rust enum
              # (emit_value_object's own branch), which needs the
              # tag<->member codec.
              f.puts Projector.emit_closed_set_codec(vo)
            elsif vo[:closed_set]
              # A multi-field closed set is a data table whose String
              # fields are &'static str, not String — from_json can only
              # select one of the table's fixed rows, not construct one.
              f.puts Projector.emit_closed_set_table_codec(vo)
            else
              # A value object gets the same unknown-key refusal a
              # command's args struct gets, with no extra allowed keys —
              # without it, a mistyped nested VO field silently falls
              # through to any declared default instead of being refused.
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

            # An entity nested inside this one (one level past what this
            # loop otherwise reaches). Its struct and JSON codec are needed
            # the moment a sibling field references it as a Vec<...>
            # element type. Its own commands route only via `to: {
            # entities: [...] }` addressing (ADR 0026); a third level is
            # deliberately not generalized.
            #
            # entity_can_route (used again in the nested-entities loop
            # below) gates whether this entity's identity shape supports
            # extract_id/extract_wants at all; nested_can_route is the same
            # check one hop deeper. Both true is what unrouted_supported
            # (below) gates.
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
              # identity() is what a routed dispatch needs off a
              # doubly-nested element, emitted unconditionally the same
              # way entity's own always is.
              f.puts Projector.emit_self_identity(nested)
              f.puts

              # extract_id/extract_wants for flat-args addressing at this
              # depth, gated on both hops' identity shape supporting it
              # (entity_can_route && nested_can_route) since a flat
              # dispatch must also resolve the first hop's id.
              nested_can_route = Projector.extract_id_supported?(nested)
              unrouted_supported = entity_can_route && nested_can_route
              if unrouted_supported
                f.puts Projector.emit_extract_id(nested)
                f.puts
                # The addressing sibling generated alongside extract_id: a
                # present-but-blank value is a valid non-matching
                # component here, never a refusal.
                f.puts Projector.emit_extract_id_lenient(nested)
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
                                              gap_class: "per_instance", construct: reason.construct, reason: reason)
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
                  # Matches commands.rb's emit_nested_entity_command naming
                  # exactly: dispatch_entity_#{entity.downcase}_#{nested.downcase}_#{dispatch_fn_name(cmd)}.
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
                  # Whether the router gets a flat-args fallback branch for
                  # this command, or stays routed-only; both hops must
                  # support extract_id/extract_wants (see this loop's
                  # header above).
                  unrouted_supported: unrouted_supported,
                  # registry.rb builds kernel::ArgumentGates from this
                  # command's generated gate functions (emit_argument_gates)
                  # and the kernel calls them in vocabulary order, ahead of
                  # identity resolution.
                }
              end
            end

            # Computed once above (the nested-entities loop needs it too).
            entity_router_reason = "identity #{entity[:identified_by].inspect} isn't a shape extract_id resolves yet (json_codec.rb)"
            if entity_can_route
              f.puts Projector.emit_extract_id(entity)
              f.puts
              # commands.rb's delegate_prelude/emit_entity_command and
              # registry.rb's entity_arms route-less branch both address
              # this entity by extract_id_lenient, not extract_id.
              f.puts Projector.emit_extract_id_lenient(entity)
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
                                            gap_class: "per_instance", construct: reason.construct, reason: reason)
                next
              end

              f.puts Projector.emit_entity_command(command, entity, aggregate, domain_name, value_objects_by_name, aggregates_by_name,
                                                   process_managers: ir[:process_managers])
              f.puts

              # This command's Rust function was already emitted
              # unconditionally above; whether anything can dispatch to it
              # depends on the entity's identity shape, not this command's
              # own. `generated: true, routed: false` distinguishes a
              # real-but-unreachable function from one that was never
              # generated at all.
              unless entity_can_route
                manifest << manifest_entry(kind: "entity_command", id: entity_command_verb, generated: true,
                                            routed: false, gap_class: "per_instance",
                                            construct: "router_identity", reason: "generated as a real Rust function, but not JSON-dispatchable —#{entity_router_reason}")
                next
              end

              manifest << manifest_entry(kind: "entity_command", id: entity_command_verb, generated: true, routed: true)

              entity_commands << {
                verb: entity_command_verb,
                name: command[:name],
                entity_record: entity_name,
                # Matches commands.rb's emit_entity_command naming exactly:
                # dispatch_entity_#{entity[:name].downcase}_#{dispatch_fn_name(cmd)}.
                fn: "#{entity[:name].downcase}_#{Projector.dispatch_fn_name(Projector.rust_ident(command[:name]))}",
                # EntityArgs, not Args — an aggregate command named after the
                # entity command it delegates to would otherwise share its
                # args struct's name.
                args_struct: "#{entity_name}#{Projector.rust_ident(command[:name])}EntityArgs",
                reference_checks: reference_checks(command, aggregates_by_name, unsupported_names),
                reference_specs: Projector.reference_specs(domain_name, command[:attributes]),
                # Declared attribute names; see the identical field on
                # registry_commands, above.
                attributes: command[:attributes].map { |a| a[:name].to_s },
                role: command[:role],
                # The same VO invariant/admits/pattern checks
                # emit_entity_command already bakes into dispatch_entity_*,
                # computed here too so registry.rb's router can run them
                # before refuse_role_mismatch/resolve_references, matching
                # Ruby's own dispatch order.
                invariant_check_lines: Projector.invariant_checks_for(command, aggregates_by_name, value_objects_by_name),
                # entity_name/entity_identity_reading come from the entity's
                # own declared name, threaded through registry.rb's dispatch
                # call the same way the parent aggregate's already do.
                entity_name: entity[:name],
                entity_identity_reading: entity[:identified_by].join(", "),
                # One generated function per declared argument-gate step,
                # called in vocabulary order by
                # kernel::decode_aggregate_arguments.
              }
            end
          end

          # aggregate[:attributes] plus a String-typed, always-optional
          # pseudo-attribute per `projects` field: the record's
          # struct/Fielded/JSON shape needs to carry a seeded projection
          # like any other attribute. A command's own Args struct never
          # sees this merge.
          record_attributes = aggregate[:attributes] + Projector.projected_field_pseudo_attributes(aggregate)
          record_for_struct = aggregate.merge(attributes: record_attributes)

          f.puts Projector.emit_record(record_for_struct, value_objects_by_name)
          f.puts
          f.puts Projector.emit_to_json_flat(record_name, record_attributes, value_objects_by_name, optional: true, extra_fields: lifecycle_extra_field(aggregate) + Projector.corrects_extra_fields(aggregate), aggregate: aggregate)
          f.puts
          f.puts Projector.emit_from_json_state(record_name, record_attributes, value_objects_by_name, optional: true, extra_fields: lifecycle_extra_field(aggregate) + Projector.corrects_extra_fields(aggregate), aggregate: aggregate)
          f.puts
          # dispatch/dispatch_entity are generic over the record type and
          # need a trait-bound to_json, since the inherent method above
          # can't be called on a bare generic T. Emitted only for
          # aggregate records, never value objects/entities/Args structs.
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
              manifest << manifest_entry(kind: "command", id: command_verb, generated: false, gap_class: "per_instance", construct: reason.construct, reason: reason)
              next
            end

            f.puts Projector.emit_command(command, aggregate, domain_name, value_objects_by_name, aggregates_by_name)
            f.puts
            args_struct = "#{Projector.rust_ident(command[:name])}Args"
            # An event's payload is args.to_json() directly, matching what
            # a policy or process-manager reaction needs to forward real
            # data into a re-triggered command's from_json.
            #
            # Not sparse: true here — that would diverge this generator's
            # output from the separate hecks-codegen reimplementation that
            # spec/codegen_parity_spec.rb holds byte-identical to this one,
            # across nearly every domain with an optional command attribute.
            f.puts Projector.emit_to_json_flat(args_struct, command[:attributes], value_objects_by_name, sparse: true)
            f.puts
            allowlist = Projector.command_argument_allowlist(aggregate, command, ir[:process_managers])
            f.puts Projector.emit_from_json_flat(args_struct, command[:attributes], value_objects_by_name, unknown_argument_allowlist: allowlist, command_name: command[:name].to_s, absent_argument_check: true, interleave_checks: true, aggregates_by_name: aggregates_by_name)
            f.puts
            # One generated function per declared argument-gate step,
            # called in vocabulary order by
            # kernel::decode_aggregate_arguments.
            f.puts Projector.emit_argument_gates(args_struct, command[:name].to_s, command[:attributes], allowlist)
            f.puts

            # A creating command's identity comes from its own typed args
            # (build_identity_expr, already emitted by emit_command), so
            # it's routable regardless of extract_id — including when
            # identity needs an extra `head:` parameter read off the raw
            # JSON rather than the typed Args struct. An acting command's
            # id comes from extract_id instead, so it's routable only
            # when that is.
            creates = Projector.creates_owner?(aggregate, command, value_objects_by_name)
            # identity_components only applies to a creating command: an
            # acting command reaches an existing record via
            # extract_id/id_line, not by minting one, so it never needs
            # these extra params.
            identity_extra_params = creates ? Projector.identity_components(aggregate, command).filter_map { |c| c[:head] } : []

            unless creates || can_route
              puts "skipping #{command_verb}'s JSON router entry: #{acting_router_reason}"
              manifest << manifest_entry(kind: "command", id: command_verb, generated: true, routed: false,
                                          gap_class: "per_instance",
                                          construct: "router_identity", reason: "generated as a real Rust function, but not JSON-dispatchable —#{acting_router_reason}")
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
              # Adds only entries reference_checks above doesn't already
              # cover — a reference field redeclared under a plain value
              # object, checked against the aggregate's own field of the
              # same name (ADR 0037).
              reference_checks: reference_checks(command, aggregates_by_name, unsupported_names) +
                state_reference_checks(aggregate, command, aggregates_by_name, unsupported_names, value_objects_by_name),
              # tenant_boundary_checks' own header has the full argument.
              # Empty for every command outside tenant_ledger today — no
              # other aggregate in the corpus declares a tenant-scoping
              # query.
              tenant_boundary_checks: tenant_boundary_checks(aggregate, command, aggregates_by_name, unsupported_names, value_objects_by_name),
              reference_specs: Projector.reference_specs(domain_name, command[:attributes]),
              # Read by reactions.rb's emit_command_attributes_table and
              # ReactionInvocation.command_facts on the Ruby side.
              attributes: command[:attributes].map { |a| a[:name].to_s },
              role: command[:role],
              # See the identical field on entity_commands, above, for the
              # full reasoning.
              invariant_check_lines: Projector.invariant_checks_for(command, aggregates_by_name, value_objects_by_name),
              # registry.rb builds kernel::ArgumentGates from this
              # command's generated gate functions (emit_argument_gates)
              # and the kernel calls them in vocabulary order, ahead of
              # identity resolution.
            }
          end

          # The primary/driving half (ports.rb's own header): no Hydrate,
          # no repo, so can_route never gates these — the operation's own
          # reference attribute already names the record.
          aggregate[:ports].each do |port|
            port[:operations].each do |operation|
              operation_verb = "#{domain_name}::#{aggregate[:name]}.#{port[:name]}.#{operation[:name]}"
              reason = Projector.port_operation_skip_reason(operation, aggregate[:name], value_objects_by_name)
              if reason
                puts "skipping #{operation_verb}: #{reason}"
                manifest << manifest_entry(kind: "port_operation", id: operation_verb, generated: false,
                                            gap_class: "per_instance", construct: reason.construct, reason: reason)
                next
              end

              f.puts Projector.emit_port_operation(operation, port[:name], aggregate[:name], domain_name, value_objects_by_name, aggregates_by_name)
              f.puts

              manifest << manifest_entry(kind: "port_operation", id: operation_verb, generated: true, routed: true)
              operation_args_struct = "#{Projector.rust_ident(port[:name])}#{Projector.rust_ident(operation[:name])}Args"
              # If this operation still declares a Reference-typed
              # attribute pointing back at its own aggregate,
              # emit_port_operation excludes it from the generated args
              # struct (routing supplies the receiver now), so filter it
              # out of reference checks too.
              legacy_receiver_field = operation[:attributes]
                .find { |attr| Projector.reference_target(attr[:type]) == aggregate[:name] }
                &.dig(:name)
              # Mirrors Dispatcher#port_invocation's additive branch: no
              # Reference-typed attribute exists for a `to:`-declared
              # operation, so the receiver comes from a plain fact
              # attribute named for the owning aggregate's own
              # identified_by field instead. Kept as a separate field
              # since split_aggregate_receiver must not strip it from the
              # payload — it's a real declared fact, not routing-only
              # state. Uses `.split(".").first` to take just the head of
              # identified_by, since a value-object-typed identity
              # resolves to a dotted internal path rather than the flat
              # name the operation's own attribute is actually named.
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
          # Carried through verbatim; emit_identity_head_table only
          # resolves the single-component case — a composite identity is
          # a documented gap there, not silently assumed to work.
          identified_by: aggregate[:identified_by],
          # Name + identity paths only; a saga-dispatched entity command
          # needs the entity's own identity, not just its parent
          # aggregate's.
          entities: aggregate[:entities].map { |e| { name: e[:name], identified_by: e[:identified_by] } },
          # Which top-level generated module this aggregate's .rs file
          # lives under, so a per-chapter registry.rs can qualify
          # cross-file paths as crate::generated::#{chapter_mod}::...
          # instead of a bare super::...
          chapter_mod: mod_name,
          # This aggregate's own declared reference_to/belongs_to
          # attributes, for the domain-wide REFERENCE_TABLE and an acting
          # command's owner_deref fetch — computed once here rather than
          # re-derived per command.
          reference_specs: Projector.reference_specs(domain_name, aggregate[:attributes]),
          # The bluebook's declared name (e.g. "Governance", not the
          # lowercase module), so a merged multi-chapter registry labels
          # each record by its own chapter correctly.
          domain_name: domain_name,
        }
      end

      # A declared query now generates for real for the subset
      # query_skip_reason admits (field-comparator conditions, order_by,
      # limit, offset, a nulls override); anything else is a
      # per-instance gap, not a whole-kind one, since the construct kind
      # has a real code path.
      query_aggregates_by_name = ir[:aggregates].to_h { |a| [a[:name], a] }
      assignments_verb = Projector.provided_assignments(ir)
      ir[:aggregates].each do |aggregate|
        value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }

        aggregate[:queries].each do |query|
          query_verb = "#{domain_name}::#{aggregate[:name]}.#{query[:name]}"
          reason = Projector.query_skip_reason(query, aggregate, value_objects_by_name, query_aggregates_by_name)
          if reason
            puts "skipping query #{query_verb}: #{reason}"
            manifest << manifest_entry(kind: "query", id: query_verb, generated: false, gap_class: "per_instance", construct: reason.construct, reason: reason)
            next
          end

          manifest << manifest_entry(kind: "query", id: query_verb, generated: true)
          conditions, reference_hop_conditions = Projector.query_conditions_and_hops(domain_name, query, aggregate, query_aggregates_by_name)
          query_defs << {
            verb: query_verb,
            aggregate: "#{domain_name}::#{aggregate[:name]}",
            arg_checks: Projector.query_arg_checks(query, "crate::generated::#{mod_name}::#{aggregate[:name].downcase}",
                                                   value_objects_by_name),
            conditions: conditions,
            reference_hop_conditions: reference_hop_conditions,
            order_by: query[:order_by] ? Projector.emit_query_order_by(query[:order_by], query[:null_semantics]) : nil,
            offset: query[:offset] ? Projector.emit_query_offset(query[:offset]) : nil,
            limit: query[:limit] ? Projector.emit_query_limit(query[:limit]) : nil,
            authorization: Projector.emit_query_authorization(query[:name], query[:authorization]),
            assignments: assignments_verb == "#{aggregate[:name]}.#{query[:name]}",
          }
        end

        # Generated when the aggregate holds the entity in a list
        # (kernel::named_query::run_entity). A query on an entity nested
        # inside another entity stays a recorded gap.
        aggregate_id = "#{domain_name}::#{aggregate[:name]}"
        aggregate[:entities].each do |entity|
          list_attr = aggregate[:attributes].find { |a| a[:list] && a[:type].to_s == entity[:name].to_s }
          Array(entity[:queries]).each do |query|
            query_verb = "#{aggregate_id}.#{entity[:name]}.#{query[:name]}"
            reason = Projector.entity_query_skip_reason(query, entity, list_attr, value_objects_by_name)
            if reason
              puts "skipping query #{query_verb}: #{reason}"
              manifest << manifest_entry(kind: "query", id: query_verb, generated: false, gap_class: "per_instance", construct: reason.construct, reason: reason)
              next
            end

            manifest << manifest_entry(kind: "query", id: query_verb, generated: true)
            query_defs << {
              verb: query_verb,
              aggregate: aggregate_id,
              entity: { list_field: list_attr[:name].to_s, parent_key: Projector.snake(aggregate[:name]),
                        identity_keys: Array(entity[:identified_by]).map { |path| path.to_s.split(".").first } },
              arg_checks: [],
              conditions: Projector.query_conditions(query),
              order_by: query[:order_by] ? Projector.emit_query_order_by(query[:order_by], query[:null_semantics]) : nil,
              offset: query[:offset] ? Projector.emit_query_offset(query[:offset]) : nil,
              limit: query[:limit] ? Projector.emit_query_limit(query[:limit]) : nil,
              authorization: nil,
            }
          end
          manifest.concat(entity_query_entries("#{aggregate_id}.#{entity[:name]}", Array(entity[:entities])))
        end
      end

      # A declared report block now generates for real for the subset
      # read_model_skip_reason admits (a root aggregate fetched by
      # reference id, plus reference-matched sibling heads — no
      # where/order_by/limit). Anything else is a per-instance gap, not a
      # whole-kind one, matching the query codegen above.
      read_model_defs = []
      ir[:read_models].each do |read_model|
        read_model_id = "#{domain_name}::#{read_model[:name]}"
        reason = Projector.read_model_skip_reason(read_model, aggregates_by_name, unsupported_names)
        if reason
          puts "skipping read_model #{read_model_id}: #{reason}"
          manifest << manifest_entry(kind: "read_model", id: read_model_id, generated: false, gap_class: "per_instance", construct: reason.construct, reason: reason)
          next
        end

        manifest << manifest_entry(kind: "read_model", id: read_model_id, generated: true)
        read_model_defs << Projector.read_model_def(domain_name, read_model, aggregates_by_name)
      end

      # A same-domain policy generates into POLICIES and dispatches
      # locally; a cross-domain policy generates into the separate
      # CROSS_DOMAIN_POLICIES table instead, delivered by rust/host's
      # lambda_client.rs rather than a local dispatch_by_name call. This
      # manifest entry can't attest that a live cross-domain reaction's
      # target actually exists — that's an operational fact about a real
      # deploy, not something codegen can check.
      ir[:policies].each do |policy|
        manifest << manifest_entry(kind: "policy", id: "#{domain_name}::#{policy[:name]}", generated: true, routed: true)
      end

      # Unlike emit_policy_table above, no process manager has a
      # per-instance skip condition: every declared dispatch target is
      # already fully domain-qualified on the wire.
      ir[:process_managers].each do |pm|
        manifest << manifest_entry(kind: "process_manager", id: "#{domain_name}::#{pm[:name]}", generated: true, routed: true)
      end

      # Which adapter an aggregate is bound to is a deployment fact, not
      # something re-derived from the bluebook's shape. Always generated
      # and routed: rust/host's journal read/write path is generic over
      # storage_name, and reachable outside the WASM kernel/cli.rs match
      # arm entirely.
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
        f.puts "// GENERATED by hecks project_rust — #{source_label}'s own canonical IR,"
        f.puts "// embedded for runtime self-description. Not read by any dispatch"
        f.puts "// function in this module — introspection only."
        f.puts "pub const IR_JSON: &str = #{Projector.rust_string_literal(JSON.pretty_generate(ir))};"
      end
      puts(wrote ? "wrote #{metadata_path}" : "#{metadata_path} unchanged")

      # rust/host carries no path dependency on this crate — its .wasm
      # module is an opaque, untrusted artifact loaded via wasmtime, so
      # metadata.rs's IR_JSON is unreachable from rust/host at compile
      # time. hecks build_wasm copies this sidecar into rust/dist/ so a
      # Rust-native web layer can read it at runtime via HECKS_IR_PATH.
      ir_json_path = File.join(mod_dir, "ir.json")
      wrote = WriteIfChanged.call(ir_json_path, JSON.pretty_generate(ir))
      puts(wrote ? "wrote #{ir_json_path}" : "#{ir_json_path} unchanged")

      # Sits alongside ir.json for the same reason: one is this call's
      # account of what it read, the other of what it did with what it
      # read. hecks rust_coverage reads both and diffs against an
      # allowlist; nothing in this generator reads manifest.json back.
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
      # This generator never writes `pub mod merged;` itself (`hecks project_rust`
      # appends it separately, only once a chapter gets its own
      # merged.rs). Re-including an already-present trailer keeps
      # WriteIfChanged's before/after comparison apples-to-apples —
      # without it, comparing base-only content against base-plus-merged
      # content on disk would look changed every run. Requires
      # merged_module too, not just presence on disk: a framework chapter
      # never regenerates merged.rs, and an orphaned trailer here would
      # leave a dangling `pub mod merged;` in the chapter's mod.rs once
      # pruning removes the file.
      merged_trailer = merged_module && File.exist?(mod_path) && File.read(mod_path).include?("pub mod merged;")
      wrote_mod = WriteIfChanged.block(mod_path) do |f|
        f.puts "// GENERATED by hecks project_rust — re-run it to refresh this list."
        f.puts "pub mod metadata;"
        f.puts "pub mod registry;"
        generated_aggregates.each { |a| f.puts "pub mod #{a[:name].downcase};" }
        f.puts "pub mod merged;" if merged_trailer
      end
      puts(wrote_mod ? "wrote #{mod_path}" : "#{mod_path} unchanged")

      # Returned so hecks project_rust can concatenate :aggregates across
      # every chapter a domain attaches into one merged
      # Store/dispatch_by_name, and :queries the same way. Each aggregate
      # already carries chapter_mod (set above); a query_def needs no
      # chapter tag since its verb/aggregate are already fully
      # domain-qualified.
      { aggregates: registry_aggregates, queries: query_defs, read_models: read_model_defs }
    end
  end
end

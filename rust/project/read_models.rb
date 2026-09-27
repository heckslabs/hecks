require_relative "skip_reason"

# Compiles declared read models into the static Rust tables
# `kernel/read_model.rs` interprets at runtime.
module RustProjection
  module Projector
    module_function

    # `group_by` is now always present on the wire (`[]` when undeclared), so
    # eligibility below must check its value, not the key's mere presence.
    READ_MODEL_BARE_KEYS = %i[name description reference_name reference_target query_name aggregate_heads
                              wheres order_by offset limit freshness index_hints group_by null_semantics
                              authorization count median_field].freeze

    # Returns nil if the read model can be generated as-is, otherwise a
    # short reason string naming what's unsupported.
    def read_model_skip_reason(read_model, aggregates_by_name, unsupported_names)
      extra = read_model.keys.map(&:to_sym) - READ_MODEL_BARE_KEYS
      return read_model_options_skip_reason(extra) if extra.any?

      # ADR 0055 lets an `on:` target a specific many-side head, but this
      # generator still assumes the first many-side head is the eligible one
      # (`read_model_filtered_head_as`), so more than one with options is refused.
      return multi_target_options_skip_reason if multi_target_options?(read_model)

      # Checked before the root lookup below: a rootless, group_by'd read
      # model has no reference_target, and reporting that as "no matching
      # aggregate head" would be misleading instead of the real reason.
      return group_by_skip_reason(read_model, aggregates_by_name, unsupported_names) if Array(read_model[:group_by]).any?

      heads = read_model[:aggregate_heads]
      root = heads.find { |head| head[:aggregate].to_s == read_model[:reference_target].to_s }
      # A rootless read model (every head reads its own whole table) has no
      # reference_target at all; only a named target with no matching head,
      # which leaves nothing for the root fetch to key off, is refused.
      if !root && !read_model[:reference_target].to_s.empty?
        return skip("missing_root_head", "declares reference_to #{read_model[:reference_target]}, but includes no matching aggregate head — " \
                                         "nothing for this generator's own root fetch to key off")
      end

      if root && !aggregates_by_name[root[:aggregate]] && nested_entity_names(aggregates_by_name).include?(root[:aggregate].to_s)
        return entity_head_skip_reason(root[:aggregate], "root", "fetch by id")
      end

      heads.each do |head|
        reason = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
        return reason if reason
      end

      reason = read_model_options_content_skip_reason(read_model, aggregates_by_name)
      return reason if reason

      aggregation_skip_reason(read_model, aggregates_by_name)
    end

    def read_model_options_skip_reason(extra)
      skip(extra.map(&:to_s).min, "declares #{extra.map(&:to_s).sort.join(', ')} — out of scope for this generator: cursor/" \
        "consistency/inspection are real " \
        "capabilities Ports::Query::InMemory/Ports::Query::Ordering/TenantScope implement that this generator " \
        "does not port (this file's own header has the full argument, the same boundary queries.rb already " \
        "draws for a declared AGGREGATE query); freshness/use_index are never disqualifying on their own — " \
        "neither is read by the in-memory interpreter path this kernel matches")
    end

    # True when more than one many-side head has where/order_by/limit/offset
    # declared — ADR 0055 permits it via `on:`, but this generator has no
    # per-head codegen yet, so that combination is refused rather than risked.
    def multi_target_options?(read_model)
      many = read_model[:aggregate_heads].count { |head| head[:many] }
      return false if many <= 1

      Array(read_model[:wheres]).any? || read_model[:order_by] || read_model[:limit] || read_model[:offset]
    end

    def multi_target_options_skip_reason
      skip("multi_target_options", "declares where/order_by/limit/offset with more than one many-side included aggregate — " \
        "ADR 0055's own `on:` lets Ruby's interpreter apply each option to a specific many-side " \
        "head, but this generator still trusts \"the first many-side head is the eligible one\" " \
        "(read_model_filtered_head_as) and has no per-head codegen yet — not generated yet, " \
        "refused rather than risk applying an option to the wrong head")
    end

    def read_model_filtered_head_as(read_model)
      declared = Array(read_model[:wheres]).any? || read_model[:order_by] || read_model[:limit] ||
                 read_model[:offset] || read_model.dig(:authorization, :tenant)
      return nil unless declared

      read_model[:aggregate_heads].find { |head| head[:many] }&.fetch(:as)
    end

    # Checks the eligible head's own where/order_by/limit for generability
    # against ITS aggregate (not the read model's root); nil means clean.
    def read_model_options_content_skip_reason(read_model, aggregates_by_name)
      eligible_as = read_model_filtered_head_as(read_model)
      return nil unless eligible_as

      head = read_model[:aggregate_heads].find { |h| h[:as].to_s == eligible_as.to_s }
      aggregate = aggregates_by_name[head[:aggregate]]
      return entity_head_skip_reason(head[:aggregate], "filtered head", "filter, order or authorize") unless aggregate

      value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }

      Array(read_model[:wheres]).each do |where|
        field = where[:field].to_s
        hop = query_hop_plan(aggregate, field, aggregates_by_name)
        if hop.nil? && field.include?("/")
          return skip("reference_hop_where", "eligible head #{head[:aggregate]}'s own where clause on #{field.inspect} hops through a " \
                 "reference this generator can't resolve yet (more than one hop, the head isn't a real " \
                 "reference attribute, or the target aggregate isn't declared in this domain) — not generated yet")
        end

        if hop
          target_value_objects_by_name = hop[:target][:value_objects].to_h { |vo| [vo[:name], vo] }
          reason = query_where_skip_reason(where.merge(field: hop[:inner_field]), hop[:target], target_value_objects_by_name)
          return reskip(reason, "eligible head #{head[:aggregate]}'s own hop through #{hop[:via_field]} to " \
                 "#{hop[:target_aggregate]}'s own #{reason}") if reason
          next
        end

        reason = query_where_skip_reason(where, aggregate, value_objects_by_name)
        return reskip(reason, "eligible head #{head[:aggregate]}'s own #{reason}") if reason
      end

      # Reused from queries.rb; checks the eligible head's own aggregate.
      auth_reason = declared_authorization_skip_reason(read_model[:authorization], aggregate, value_objects_by_name)
      return auth_reason if auth_reason

      # Defined in queries.rb; the field checks aren't read-model-specific.
      order_reason = declared_order_by_skip_reason(read_model[:order_by], aggregate, value_objects_by_name)
      return order_reason if order_reason

      offset_reason = declared_offset_skip_reason(read_model[:offset])
      return offset_reason if offset_reason

      declared_limit_skip_reason(read_model[:limit])
    end

    # `median_field`'s own eligibility, checked after where/order_by/limit
    # since count/median only reduce the already-filtered row set.
    def aggregation_skip_reason(read_model, aggregates_by_name)
      return nil unless read_model[:median_field]

      target = read_model[:aggregate_heads].find { |head| head[:many] }
      aggregate = aggregates_by_name[target[:aggregate]]
      return entity_head_skip_reason(target[:aggregate], "median target", "take a median of") unless aggregate

      value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }

      field = read_model[:median_field].to_s
      kind = query_field_kind(aggregate, field, value_objects_by_name)
      return skip("median_field", "median names #{field.inspect}, but #{target[:aggregate]} declares no such attribute — not generated yet") if kind == :unknown
      return skip("median_field", "median names #{field.inspect} on #{target[:aggregate]}, which is not numeric — median needs a numeric " \
             "field (a bare number, or a value object carrying one) — not generated yet") unless kind == :number

      nil
    end

    # Nested entity names across every aggregate (recursively) — an
    # `include` naming one of these is generated as an empty head, since
    # entities have no rows of their own to project.
    def nested_entity_names(aggregates_by_name)
      collect = lambda do |owners|
        owners.flat_map { |owner| Array(owner[:entities]).flat_map { |entity| [entity[:name].to_s, *collect.call([entity])] } }
      end
      collect.call(aggregates_by_name.values)
    end

    def entity_head_skip_reason(aggregate_name, role, purpose)
      skip("include_entity_head", "includes #{aggregate_name}, a nested entity, as the #{role} — an entity has no rows of its own " \
                                  "(ReadModelInterpreter#records reads it as empty), so there is nothing to #{purpose} — not generated yet")
    end

    def read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
      target = aggregates_by_name[head[:aggregate]]
      unless target
        return nil if nested_entity_names(aggregates_by_name).include?(head[:aggregate].to_s)

        return skip("include_undeclared_aggregate", "includes #{head[:aggregate]}, which this domain never declares")
      end
      return skip("include_unsupported_aggregate", "includes #{head[:aggregate]}, which this generator couldn't itself generate " \
                                                   "(unsupported attribute type — see this domain's own aggregate-level manifest entry)") if unsupported_names.include?(head[:aggregate])

      nil
    end

    # `group_by` eligibility, narrowed to the one shape the corpus declares:
    # a single rootless head, group_by alone (build time already guarantees
    # at most one many-side head whenever group_by is declared at all).
    def group_by_skip_reason(read_model, aggregates_by_name, unsupported_names)
      heads = read_model[:aggregate_heads]
      return skip("group_by", "declares group_by across #{heads.size} aggregate heads — not generated yet (only a single, rootless head is)") if heads.size != 1
      return skip("group_by", "declares group_by on a NON-rootless read model (reference_to #{read_model[:reference_target]}) — not generated yet") unless read_model[:reference_target].nil?
      return skip("group_by", "declares group_by alongside count/median — not generated yet") if read_model[:count] || read_model[:median_field]
      return skip("group_by", "declares group_by alongside where/order_by/limit/offset — not generated yet") if Array(read_model[:wheres]).any? || read_model[:order_by] || read_model[:limit] || read_model[:offset]
      return skip("group_by", "declares group_by with an authorize policy — not generated yet") if read_model[:authorization]

      head = heads.first
      reason = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
      return reason if reason

      aggregate = aggregates_by_name[head[:aggregate]]
      return entity_head_skip_reason(head[:aggregate], "group_by head", "group") unless aggregate
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s
      Array(read_model[:group_by]).each do |row|
        field_s = row[:field].to_s
        next if aggregate[:attributes].any? { |a| a[:name].to_s == field_s }
        next if field_s == lifecycle_field

        return skip("group_by", "group_by names #{field_s.inspect}, but #{aggregate[:name]} declares no such attribute — not generated yet")
      end

      nil
    end

    # Compiles already-confirmed-generable hop wheres into the wire shape
    # ReferenceHopCondition expects.
    def read_model_hop_conditions(domain_name, hop_wheres, aggregate, aggregates_by_name)
      hop_wheres.map do |where|
        hop = query_hop_plan(aggregate, where[:field].to_s, aggregates_by_name)
        raw_value = where[:value].to_s
        symbol = raw_value.start_with?(":")
        {
          via_field: hop[:via_field],
          target_aggregate: "#{domain_name}::#{hop[:target_aggregate]}",
          through: hop[:through].map { |step| { via_field: step[:via_field], target_aggregate: "#{domain_name}::#{step[:target_aggregate]}" } },
          inner_field: hop[:inner_field],
          op: where[:op].to_s,
          arg: symbol ? raw_value.delete_prefix(":") : nil,
          literal: symbol ? nil : Hecks::Literal.read(raw_value),
        }
      end
    end

    def emit_reference_hop_condition(hop)
      comparator_expr = "crate::kernel::query_comparators::QueryComparator::#{query_comparator_variant(hop[:op])}"
      through = Array(hop[:through]).map do |step|
        "crate::kernel::read_model::HopStep { via_field: #{step[:via_field].inspect}, target_aggregate: #{step[:target_aggregate].inspect} }"
      end
      "crate::kernel::read_model::ReferenceHopCondition { via_field: #{hop[:via_field].inspect}, " \
        "target_aggregate: #{hop[:target_aggregate].inspect}, through: &[#{through.join(', ')}], " \
        "inner_field: #{hop[:inner_field].inspect}, " \
        "inner_comparator: #{comparator_expr}, inner_value: #{emit_query_condition_value(hop)} },"
    end

    # Baked in once at codegen time — the compiled kernel has no runtime
    # attribute-type reflection. Includes every reference field regardless
    # of whether its target is a head here; the matcher simply won't match.
    def read_model_reference_fields(head_aggregate)
      head_aggregate[:attributes].filter_map do |attr|
        target = reference_target(attr[:type])
        next unless target

        { target: target, field: attr[:name] }
      end
    end

    def emit_reference_field(domain_name, reference_field)
      qualified_target = "#{domain_name}::#{reference_field[:target]}"
      "crate::kernel::read_model::ReferenceField { target_aggregate: #{qualified_target.inspect}, " \
        "field: #{reference_field[:field].to_s.inspect} }"
    end

    # Compiles one declared `include`. `is_root` is precomputed here rather
    # than re-compared at runtime; the root has no reference_fields since
    # it's fetched directly by id, never matched by reference.
    def emit_read_model_head(domain_name, head, is_root, aggregates_by_name)
      head_aggregate = aggregates_by_name[head[:aggregate]]
      reference_fields = is_root || head_aggregate.nil? ? [] : read_model_reference_fields(head_aggregate)
      reference_fields_expr = reference_fields.map { |rf| emit_reference_field(domain_name, rf) }.join(", ")
      qualified_aggregate = "#{domain_name}::#{head[:aggregate]}"

      "crate::kernel::read_model::ReadModelHead { aggregate: #{qualified_aggregate.inspect}, " \
        "as_name: #{head[:as].to_s.inspect}, many: #{head[:many] ? 'true' : 'false'}, " \
        "is_root: #{is_root ? 'true' : 'false'}, reference_fields: &[#{reference_fields_expr}] }"
    end

    # Compiles a declared order_by into Rust's ReadModelOrderBy; `descending`
    # collapses the desc/asc string check once, at codegen time.
    def emit_read_model_order_by(order_by, null_semantics = nil)
      descending = order_by[:direction].to_s == "desc" ? "true" : "false"
      "crate::kernel::read_model::ReadModelOrderBy { field: #{order_by[:field].to_s.inspect}, descending: #{descending}, " \
        "nulls: #{null_semantics_variant(null_semantics)} }"
    end

    # Compiles a declared limit into a Literal or an Arg reference; a
    # non-Arg value is already confirmed to be a real integer literal.
    def emit_read_model_limit(limit)
      raw = limit[:value].to_s
      return "crate::kernel::read_model::ReadModelLimit::Arg(#{raw.delete_prefix(':').inspect})" if raw.start_with?(":")

      "crate::kernel::read_model::ReadModelLimit::Literal(#{raw.to_i})"
    end

    # ReadModelOffset is a type alias of ReadModelLimit, so this reuses
    # emit_read_model_limit and swaps only the spelled type name.
    def emit_read_model_offset(offset) = emit_read_model_limit(offset).sub("read_model::ReadModelLimit::", "read_model::ReadModelOffset::")

    # Compiles a whole declared read model to plain data for
    # `emit_read_model_def`. `verb` uses the read model's declared name
    # ("Domain.Name"), the same convention queries.rb picks for a named
    # query — `kernel/cli.rs` tells the two shapes apart by the "::" that
    # only a Domain::Aggregate.Name query verb has before the first ".".
    #
    # `filtered_head`/`conditions`/`order_by`/`limit` are populated only when
    # `read_model_filtered_head_as` names an eligible head; skip_reason above
    # already refused anything whose content wasn't generable.
    def read_model_def(domain_name, read_model, aggregates_by_name)
      heads = read_model[:aggregate_heads].map do |head|
        is_root = head[:aggregate].to_s == read_model[:reference_target].to_s
        emit_read_model_head(domain_name, head, is_root, aggregates_by_name)
      end

      eligible_as = read_model_filtered_head_as(read_model)
      group_by_fields = Array(read_model[:group_by]).map { |row| row[:field].to_s }
      group_by_fn_name = group_by_fields.any? ? "group_by_#{read_model[:name].to_s.downcase}" : nil

      # Hop wheres need a different wire shape (ReferenceHopCondition) than
      # local ones, so they're split out below rather than reused wholesale;
      # every clause here is already confirmed resolvable or generable.
      eligible_aggregate = eligible_as && aggregates_by_name[read_model[:aggregate_heads].find { |h| h[:as].to_s == eligible_as.to_s }[:aggregate]]
      local_wheres, hop_wheres = eligible_as ? Array(read_model[:wheres]).partition { |w| query_hop_plan(eligible_aggregate, w[:field].to_s, aggregates_by_name).nil? } : [[], []]

      {
        verb: "#{domain_name}.#{read_model[:name]}",
        reference_name: read_model[:reference_name] ? read_model[:reference_name].to_s : nil,
        heads: heads,
        filtered_head: eligible_as&.to_s,
        conditions: eligible_as ? query_conditions_with_authorization(read_model.merge(wheres: local_wheres)) : [],
        reference_hop_conditions: eligible_as ? read_model_hop_conditions(domain_name, hop_wheres, eligible_aggregate, aggregates_by_name) : [],
        order_by: eligible_as && read_model[:order_by] ? emit_read_model_order_by(read_model[:order_by], read_model[:null_semantics]) : nil,
        offset: eligible_as && read_model[:offset] ? emit_read_model_offset(read_model[:offset]) : nil,
        limit: eligible_as && read_model[:limit] ? emit_read_model_limit(read_model[:limit]) : nil,
        authorization: eligible_as ? emit_query_authorization(read_model[:name], read_model[:authorization]) : nil,
        group_by_fn: group_by_fn_name,
        group_by_fn_body: group_by_fn_name ? emit_group_by_transform(group_by_fn_name, read_model[:name].to_s, aggregates_by_name[read_model[:aggregate_heads].first[:aggregate]], group_by_fields) : nil,
        count: !!read_model[:count],
        median_field: read_model[:median_field] ? read_model[:median_field].to_s : nil,
      }
    end

    # Generates the group_by transform fn by name, since the kernel's own
    # generic `run` only ever holds already-serialized Json — which value
    # object unwraps to a bare scalar is a type-level fact only codegen has.
    #
    # It re-attaches `id`, keeps only real declared attributes plus any
    # `projects` field while excluding Rust-only synthetic fields (ADR 0049),
    # and recursively unwraps single-attribute value objects. Actual grouping
    # is `kernel::read_model::nest`, which refuses a second row per leaf
    # unless `group_by_leaf_check` found the key path covers the identity.
    def emit_group_by_transform(fn_name, read_model_name, aggregate, group_by_fields)
      value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name].to_s, vo] }
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s
      fields = aggregate[:attributes] + Projector.projected_field_pseudo_attributes(aggregate)
      kept_keys = fields.map { |a| a[:name].to_s } + ["id"] + (lifecycle_field ? [lifecycle_field] : [])
      keep_cond = kept_keys.map { |k| "k == #{k.inspect}" }.join(" || ")

      arms = fields.map do |a|
        unwrapped = unwrap_json_expr("v", a[:type].to_s, a[:list], aggregate, value_objects_by_name)
        "#{a[:name].to_s.inspect} => #{unwrapped},"
      end.join("\n                    ")

      fields_literal = "&[#{group_by_fields.map(&:inspect).join(', ')}]"
      leaf_check = group_by_leaf_check(read_model_name, aggregate, group_by_fields)

      <<~RUST.rstrip
        pub fn #{fn_name}(rows: Vec<(String, crate::kernel::Json)>) -> Result<crate::kernel::Json, crate::kernel::Refusal> {
            let unwrapped: Vec<crate::kernel::Json> = rows
                .into_iter()
                .map(|(id, record)| {
                    let wrapped = crate::kernel::repository::row_json(id, record);
                    match wrapped {
                        crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(
                            fields
                                .into_iter()
                                .filter(|(k, _)| #{keep_cond})
                                .map(|(k, v)| {
                                    let new_v = match k.as_str() {
                    #{arms}
                                        _ => v,
                                    };
                                    (k, new_v)
                                })
                                .collect(),
                        ),
                        other => other,
                    }
                })
                .collect();
            crate::kernel::read_model::nest(unwrapped, #{fields_literal}, #{leaf_check})
        }
      RUST
    end

    # A key path naming every identity field of the grouped aggregate can't
    # collide, so its leaves go unchecked; any other refuses a second row
    # per leaf (ADR 0061). `identified_by` in the IR holds identity paths.
    def group_by_leaf_check(read_model_name, aggregate, group_by_fields)
      identity = Array(aggregate[:identified_by]).map { |path| path.to_s.split(".").first }.uniq
      return "crate::kernel::read_model::LeafCheck::IdentityCovered" if identity.any? && (identity - group_by_fields).empty?

      "crate::kernel::read_model::LeafCheck::RefuseCollision(#{read_model_name.inspect})"
    end

    # Ports Value.materialize_unwrapped: a single-attribute value object
    # unwraps to its bare field; a multi-attribute one or an entity keeps
    # its object shape but recurses into each field; scalars and lists
    # (mapped element-wise) pass through the same logic unchanged.
    def unwrap_json_expr(expr, type_name, list, aggregate, value_objects_by_name)
      if list
        inner = unwrap_json_expr("item", type_name, false, aggregate, value_objects_by_name)
        return "match #{expr} { crate::kernel::Json::Array(items) => crate::kernel::Json::Array(items.into_iter().map(|item| #{inner}).collect()), other => other }"
      end

      vo = value_objects_by_name[type_name]
      entity = (aggregate[:entities] || []).find { |e| e[:name].to_s == type_name.to_s }
      fields_meta = vo ? vo[:attributes] : (entity ? entity[:attributes] : nil)
      return expr unless fields_meta

      if vo && fields_meta.size == 1
        field = fields_meta.first
        unwrapped = unwrap_json_expr("field_value", field[:type].to_s, field[:list], aggregate, value_objects_by_name)
        return "match #{expr} { crate::kernel::Json::Object(fields) => fields.into_iter().find(|(k, _)| k == #{field[:name].to_s.inspect}).map(|(_, field_value)| #{unwrapped}).unwrap_or(crate::kernel::Json::Null), other => other }"
      end

      inner_arms = fields_meta.map do |f|
        unwrapped = unwrap_json_expr("v", f[:type].to_s, f[:list], aggregate, value_objects_by_name)
        "#{f[:name].to_s.inspect} => #{unwrapped},"
      end.join(" ")
      "match #{expr} { crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(fields.into_iter().map(|(k, v)| { let new_v = match k.as_str() { #{inner_arms} _ => v }; (k, new_v) }).collect()), other => other }"
    end

    def emit_read_model_def(read_model_def)
      heads = read_model_def[:heads].map { |head| "        #{head}," }.join("\n")
      conditions = read_model_def[:conditions].map { |c| "        #{emit_query_condition(c)}" }.join("\n")
      reference_hop_conditions = read_model_def[:reference_hop_conditions].map { |h| "        #{emit_reference_hop_condition(h)}" }.join("\n")
      filtered_head = read_model_def[:filtered_head] ? "Some(#{read_model_def[:filtered_head].inspect})" : "None"
      order_by = read_model_def[:order_by] ? "Some(#{read_model_def[:order_by]})" : "None"
      offset = read_model_def[:offset] ? "Some(#{read_model_def[:offset]})" : "None"
      limit = read_model_def[:limit] ? "Some(#{read_model_def[:limit]})" : "None"
      authorization = read_model_def[:authorization] ? "Some(#{read_model_def[:authorization]})" : "None"
      reference_name = read_model_def[:reference_name] ? "Some(#{read_model_def[:reference_name].inspect})" : "None"
      group_by = read_model_def[:group_by_fn] ? "Some(#{read_model_def[:group_by_fn]})" : "None"
      count = read_model_def[:count] ? "true" : "false"
      median_field = read_model_def[:median_field] ? "Some(#{read_model_def[:median_field].inspect})" : "None"

      <<~RUST.rstrip
        crate::kernel::read_model::ReadModelDef {
            verb: #{read_model_def[:verb].inspect},
            reference_name: #{reference_name},
            heads: &[
        #{heads}
            ],
            filtered_head: #{filtered_head},
            conditions: &[
        #{conditions}
            ],
            reference_hop_conditions: &[
        #{reference_hop_conditions}
            ],
            order_by: #{order_by},
            offset: #{offset},
            limit: #{limit},
            authorization: #{authorization},
            group_by: #{group_by},
            count: #{count},
            median_field: #{median_field},
        },
      RUST
    end

    # Must dedent-match `rust/src/exemplar/read_models.rs`'s own
    # TMPL:read_model_table placeholder row exactly — Exemplar.render
    # substitutes by literal substring.
    READ_MODEL_TABLE_ROW_PLACEHOLDER = <<~RUST.rstrip
      crate::kernel::read_model::ReadModelDef {
          verb: "tmpl_verb",
          reference_name: Some("tmpl_reference_name"),
          heads: &[
              crate::kernel::read_model::ReadModelHead {
                  aggregate: "tmpl_aggregate",
                  as_name: "tmpl_as_name",
                  many: true,
                  is_root: false,
                  reference_fields: &[
                      crate::kernel::read_model::ReferenceField { target_aggregate: "tmpl_target_aggregate", field: "tmpl_field" },
                  ],
              },
          ],
          filtered_head: Some("tmpl_as_name"),
          conditions: &[
              crate::kernel::QueryCondition {
                  field: "tmpl_field",
                  comparator: crate::kernel::query_comparators::QueryComparator::Eq,
                  value: crate::kernel::QueryConditionValue::Literal("tmpl_literal"),
              },
          ],
          reference_hop_conditions: &[
              crate::kernel::read_model::ReferenceHopCondition {
                  via_field: "tmpl_via_field",
                  target_aggregate: "tmpl_target_aggregate",
                  through: &[crate::kernel::read_model::HopStep { via_field: "tmpl_via_field", target_aggregate: "tmpl_target_aggregate" }],
                  inner_field: "tmpl_inner_field",
                  inner_comparator: crate::kernel::query_comparators::QueryComparator::Eq,
                  inner_value: crate::kernel::QueryConditionValue::Literal("tmpl_literal"),
              },
          ],
          order_by: Some(crate::kernel::read_model::ReadModelOrderBy { field: "tmpl_order_field", descending: true, nulls: crate::kernel::query_ordering::NullsMode::Last }),
          offset: Some(crate::kernel::read_model::ReadModelOffset::Literal(1)),
          limit: Some(crate::kernel::read_model::ReadModelLimit::Literal(5)),
          authorization: Some(crate::kernel::named_query::TenantAuth { query_name: "tmpl_query_name", tenant_field: "tmpl_tenant_field", policy: "tmpl_policy" }),
          group_by: None,
          count: false,
          median_field: None,
      },
    RUST

    # The read model table `kernel::read_model::run` walks at runtime — one
    # row per read model that `read_model_skip_reason` lets through; a
    # skipped read model simply has no row here.
    def emit_read_model_table(read_model_defs)
      rows = read_model_defs.map { |rmd| emit_read_model_def(rmd) }
      Exemplar.render("read_model_table", READ_MODEL_TABLE_ROW_PLACEHOLDER => rows.join("\n"))
    end
  end
end

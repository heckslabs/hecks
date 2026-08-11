module RustProjection
  module Projector
    module_function

    # ── READ MODEL CODEGEN — the subset of a declared `report "X" do
    # ... end` block (IR::ReadModel — the `read_model` construct;
    # `report` is the language's own word for it, per syntax.bluebook's
    # `was: "read_model"`) expressible as: a ROOT aggregate fetched by
    # its own reference id, plus one or more OTHER aggregate heads found
    # by scanning and matching a REFERENCE FIELD back to an
    # already-projected root/sibling row. Exactly `kernel/repository.rs`'s
    # existing `AggregateScan`/`filter_entries`-adjacent scan primitive
    # (`AggregateScan::scan`, reused directly — no NEW kernel scanning
    # primitive was needed) plus a hand-written matcher
    # (`kernel/read_model.rs`) that walks it the same "compile shapes,
    # interpret behavior" way `named_query.rs` already walks a generated
    # `QUERIES` table.
    #
    # GROUND TRUTH: `Runtime::ReadModelInterpreter#project`
    # (lib/hecksagain/runtime/read_model_interpreter.rb), read directly —
    # resolve the root by id, walk every declared head ROOT-FIRST for
    # COMPUTATION regardless of `include` order (a real, once-live bug:
    # a many-side head declared before its own root silently matched
    # against an empty `projected` and came back too small — see
    # `kernel/read_model.rs`'s own header for the full citation), match
    # every OTHER head's own reference attributes against whichever
    # heads are already in `projected`, then materialize in DECLARED
    # order for the OUTPUT even though the computation above needed
    # root-first.
    #
    # WHAT THIS DELIBERATELY DOES NOT COVER, AND WHY — read together with
    # `read_model_skip_reason` below:
    #
    #   ANY option beyond the bare reference+heads shape — `where`,
    #   `order_by`, `limit`, `offset`, `cursor`, `consistency`,
    #   `freshness`, `authorize` (TenantScope), `nulls`, `inspect_query`,
    #   `use_index`. This is NOT the same boundary `queries.rb` draws for
    #   a declared AGGREGATE query (which draws the line at "this
    #   generator doesn't implement sorting/paging yet"): for a READ
    #   MODEL specifically, `where`/`order_by`/`limit` are STRUCTURALLY
    #   ABSENT from the canonical IR this generator reads at all —
    #   `IR::ReadModel#to_h` (lib/hecksagain/bluebook/ir/read_model.rb)
    #   deliberately never serializes them. `language/bluebook/
    #   syntax.bluebook`'s own comment on `ReadModel`'s `where`/
    #   `order_by`/`limit` member rows says so in as many words: "Same
    #   three words, same builder module, different landing —
    #   `ReadModel#to_h` omits wheres/order_by/limit, so they have never
    #   been in the IR contract and the language holds them as option
    #   rows instead." `meta_validator.rb`'s own later comment confirms
    #   this is a deliberate, permanent design choice, not a gap waiting
    #   to be closed: a SEPARATE mechanism (`Bluebook::Assembly::
    #   Reconstruction`, reading a bluebook's own filter/order/limit back
    #   off the meta-domain's dispatched records) now exists for
    #   self-hosted round-tripping, but explicitly leaves the WIRE FORMAT
    #   — the same `to_h`/`ir.json` this whole `rust/project/` tree reads
    #   — untouched: "to_h is a PROJECTION and the language is the
    #   SOURCE. They must agree about everything to_h spells; they need
    #   not be the same size... the wire format did not move an inch."
    #   `bin/project_rust`'s entire codegen pipeline reads ONLY that same
    #   `to_h`-derived `ir.json` — there is no data here to bake a
    #   filter/sort/cap from, not "not yet ported," structurally absent
    #   from the one input this generator is built to read. Detected as
    #   a side effect of checking for any key beyond the bare shape
    #   (`freshness`/`index_hints`/etc DO survive `to_h`'s own
    #   `extra_options_to_h` — only `wheres`/`order_by`/`limit`
    #   themselves are excluded — so their presence is an honest, visible
    #   signal that a where/order_by/limit MIGHT also be declared, the
    #   only signal this generator can see at all).
    #
    #   `TenantScope` (an `authorize policy, tenant: :field` boundary) —
    #   covered by the bare-shape check above (a declared `authorize`
    #   survives into `extra_options_to_h`, so any read model declaring
    #   one is already excluded before a TenantScope-specific check would
    #   even matter). No real corpus read model declares one today
    #   (confirmed by reading all three declarations directly — see
    #   `bin/rust_coverage`'s own ALLOWLIST entry for this generator).
    #
    #   Adapter-native `query_read_model` pushdown (Postgres/SQL) — this
    #   kernel has no SQL adapter at all, the same structural N/A
    #   `queries.rb`'s own header and the era/lineage gap already
    #   establish for this codebase; `kernel/read_model.rs`'s in-process
    #   loop is the only path, matching Ruby's own in-process fallback
    #   (`ReadModelInterpreter#project`'s `unless rootless ||
    #   model.group_by.any?` early-return never fires for anything this
    #   generator admits, since none of it is rootless or group_by'd
    #   either — see below).
    #
    #   `rootless` read models and `group_by` — features that exist on
    #   this codebase's OWN `main` branch (a later `ReadModelInterpreter`
    #   than the one this branch carries), not on `feat/rust-projection`
    #   at all: THIS branch's `IR::ReadModel` has no `reference_target`-
    #   nilable/`group_by` concept for a bluebook author to even declare,
    #   so there is structurally nothing here to skip — noted for a
    #   future reader diffing this generator against a newer
    #   `read_model_interpreter.rb`, not a corner this generator cuts
    #   today.
    READ_MODEL_BARE_KEYS = %i[name description reference_name reference_target query_name aggregate_heads].freeze

    # One declared read model's own eligibility — `nil` (clean) or a
    # specific, honest reason string, the same "one gate every other
    # function answers to" shape `queries.rb`'s own `query_skip_reason`
    # already holds to.
    def read_model_skip_reason(read_model, aggregates_by_name, unsupported_names)
      extra = read_model.keys.map(&:to_sym) - READ_MODEL_BARE_KEYS
      return read_model_options_skip_reason(extra) if extra.any?

      heads = read_model[:aggregate_heads]
      root = heads.find { |head| head[:aggregate].to_s == read_model[:reference_target].to_s }
      return "declares reference_to #{read_model[:reference_target]}, but includes no matching aggregate head — " \
             "nothing for this generator's own root fetch to key off (every real corpus read model includes its " \
             "own reference target; this generator refuses rather than guess at a root-less shape it doesn't cover)" unless root

      heads.each do |head|
        reason = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
        return reason if reason
      end

      nil
    end

    def read_model_options_skip_reason(extra)
      "declares #{extra.map(&:to_s).sort.join(', ')} — IR::ReadModel#to_h structurally never exports " \
        "where/order_by/limit clause data at all (a documented language design choice, not a generator gap — see " \
        "this file's own header for the full citation), so a read model declaring any option beyond the bare " \
        "reference+heads shape has real filtering/ordering/paging/tenant behavior this generator has no data to " \
        "reconstruct from the canonical IR bin/project_rust actually reads; baking a heads-only answer would " \
        "silently drop it, exactly the wrong shape this whole project refuses to ship"
    end

    def read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
      target = aggregates_by_name[head[:aggregate]]
      return "includes #{head[:aggregate]}, which this domain never declares" unless target
      return "includes #{head[:aggregate]}, which this generator couldn't itself generate " \
             "(unsupported attribute type — see this domain's own aggregate-level manifest entry)" if unsupported_names.include?(head[:aggregate])

      nil
    end

    # `head_aggregate`'s own reference attributes, each paired with the
    # bare aggregate name it targets — `Runtime::ReadModelInterpreter#
    # reference_fields`, read directly: `aggregate.attributes.select {
    # attribute.reference? && attribute.type.target_name == target.to_s
    # }.map(&:name)`, just not narrowed to one `target` at a time the way
    # Ruby's own runtime re-derives it per candidate `source` — baked in
    # ONCE per head at codegen time instead, since this compiled kernel
    # has no runtime attribute-type reflection the way a live Ruby
    # `IR::Attribute` does. Every reference attribute is included
    # regardless of whether its OWN target is even a head on this same
    # read model (unlike Ruby, which only ever asks about a target that
    # IS already in `projected`) — harmless: `kernel/read_model.rs`'s own
    # matcher only ever finds a hit when the target genuinely is among
    # the heads already computed, so a reference field whose target
    # never appears here simply never contributes a match, the same
    # observable answer either way.
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

    # ONE declared `include`, compiled — `is_root` precomputed once here
    # (`head[:aggregate] == read_model[:reference_target]`) rather than
    # re-compared at runtime against a stored `reference_target` string
    # on every call, and `reference_fields` left EMPTY for the root: the
    # root is never matched by reference at all, it's fetched directly
    # by the caller's own id argument (`kernel/read_model.rs`'s own
    # `run`, mirroring `ReadModelInterpreter#project`'s own `if
    # head[:aggregate] == model.reference_target` branch).
    def emit_read_model_head(domain_name, head, is_root, aggregates_by_name)
      reference_fields = is_root ? [] : read_model_reference_fields(aggregates_by_name[head[:aggregate]])
      reference_fields_expr = reference_fields.map { |rf| emit_reference_field(domain_name, rf) }.join(", ")
      qualified_aggregate = "#{domain_name}::#{head[:aggregate]}"

      "crate::kernel::read_model::ReadModelHead { aggregate: #{qualified_aggregate.inspect}, " \
        "as_name: #{head[:as].to_s.inspect}, many: #{head[:many] ? 'true' : 'false'}, " \
        "is_root: #{is_root ? 'true' : 'false'}, reference_fields: &[#{reference_fields_expr}] }"
    end

    # A whole declared read model, compiled to the plain data
    # `emit_read_model_def` renders — `verb` is the "Domain.Name" wire
    # string `kernel/cli.rs`'s STRING-form "query" step matches a
    # read-model ask against (that file's own header on how it tells
    # this shape apart from a named/declared AGGREGATE query's
    # "Domain::Aggregate.Name" shape: the presence of "::" before the
    # first "."), using the read model's own DECLARED name — the same
    # convention `queries.rb`'s own `query_def[:verb]` already picked
    # for a named query, not the snake-cased `query_name` `Runtime::
    # Dispatcher#query` would ALSO accept (`bluebook.read_model(named)`
    # matches either spelling in Ruby; this generator only ever needs to
    # emit one, and picks the same style precedent already set).
    def read_model_def(domain_name, read_model, aggregates_by_name)
      heads = read_model[:aggregate_heads].map do |head|
        is_root = head[:aggregate].to_s == read_model[:reference_target].to_s
        emit_read_model_head(domain_name, head, is_root, aggregates_by_name)
      end

      {
        verb: "#{domain_name}.#{read_model[:name]}",
        reference_name: read_model[:reference_name].to_s,
        heads: heads,
      }
    end

    def emit_read_model_def(read_model_def)
      heads = read_model_def[:heads].map { |head| "        #{head}," }.join("\n")
      <<~RUST.rstrip
        crate::kernel::read_model::ReadModelDef {
            verb: #{read_model_def[:verb].inspect},
            reference_name: #{read_model_def[:reference_name].inspect},
            heads: &[
        #{heads}
            ],
        },
      RUST
    end

    # The exact dedented text of `rust/src/exemplar/read_models.rs`'s own
    # `TMPL:read_model_table` placeholder ROW — `Exemplar.render`'s
    # substitution is a literal substring match, so this has to reproduce
    # that file's exact spacing, matching `queries.rb`'s own
    # `QUERY_TABLE_ROW_PLACEHOLDER` precedent exactly.
    READ_MODEL_TABLE_ROW_PLACEHOLDER = <<~RUST.rstrip
      crate::kernel::read_model::ReadModelDef {
          verb: "tmpl_verb",
          reference_name: "tmpl_reference_name",
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
      },
    RUST

    # ── THE READ MODEL TABLE — `kernel::read_model::run`'s own static
    # data, `Runtime::ReadModelInterpreter#project` ported to generated
    # `ReadModelDef` rows a hand-written, generic function walks
    # (kernel/read_model.rs), the SAME "compile shapes, interpret
    # behavior" split `emit_query_table`/`emit_policy_table` already hold
    # to. One row per read model `read_model_skip_reason` (above) lets
    # through — a skipped one simply has no row here at all.
    def emit_read_model_table(read_model_defs)
      rows = read_model_defs.map { |rmd| emit_read_model_def(rmd) }
      Exemplar.render("read_model_table", READ_MODEL_TABLE_ROW_PLACEHOLDER => rows.join("\n"))
    end
  end
end

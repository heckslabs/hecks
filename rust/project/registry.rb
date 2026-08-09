module RustProjection
  module Projector
    module_function

    # ── THE JSON COMMAND ROUTER — `dispatch_by_name`'s own per-domain
    # table, generated once (domain_generator.rb calls this last, after
    # every aggregate's own file is written). One `Store` field per
    # generated aggregate — an `InMemoryRepository<T>`, the only
    # `Repository` impl this kernel ships (kernel/repository.rs) — and one
    # match arm per generated command (`command_skip_reason`'s survivors
    # only; a skipped command was never given a `dispatch_*` function to
    # route to either). `kernel/cli.rs` is the one caller: it knows verbs
    # and JSON, nothing domain-specific: this table is the whole bridge.
    #
    # `aggregates` is `[{name:, mod:, record:, commands: [{verb:, fn:,
    # args_struct:, creates:, reference_checks:, role:}], entity_commands:
    # [{verb:, entity_record:, fn:, args_struct:, reference_checks:,
    # role:}]}]` — accumulated by domain_generator.rb while it walks the
    # real IR, not re-derived here. `reference_checks` is `[{field:,
    # optional:, target_mod:, target_name:, heads:}]` (`domain_generator.
    # rb`'s own `reference_checks` helper) — `CommandRules::References
    # #resolve_references`'s per-attribute walk, done at codegen time
    # instead of dispatch time. `role:` is the command's own declared
    # role string, or `nil` (most commands declare none) — `IR::Command
    # #role`, exported verbatim.
    #
    # Both emitted HERE, in the router, rather than inside each command's
    # own `dispatch_*` function (commands.rb):
    #   - `resolve_references` needs `store` — every OTHER aggregate's
    #     repo, not just this command's own — which only exists at this
    #     level, the same way Ruby's own version reaches through
    #     `@registry.repository(domain, target)` rather than anything
    #     local to one command.
    #   - `refuse_role_mismatch` needs the CALLER's role, which arrives
    #     as this router's own `caller_role` parameter (`cli.rs`'s own
    #     per-step `role:` key) — commands.rb's generated functions have
    #     no equivalent parameter and shouldn't grow one just for this.
    # Emitted right after `from_json` succeeds and before the real
    # dispatch call, matching Ruby's own `DISPATCH_ORDER`: `refuse_role_
    # mismatch` then `resolve_references` run in that order, both after
    # argument normalization/coercion and strictly before `hydrate`/
    # `enforce_givens` — verified live: a dangling reference (0016's own
    # investigation) or a role mismatch is refused before the command's
    # OWN `given`s are even consulted.
    # `command_name` is the SHORT name (`command.hecks_name` — "Open",
    # not the qualified verb "Banking::Account.Open") — confirmed against
    # Ruby's own live wording: `"Open refused — role: Branch clerk, and
    # the caller stated Wrong Role"`.
    def emit_role_check(role, command_name)
      return nil unless role

      Exemplar.render("role_check", '"TmplRole"' => role.inspect, '"TmplCommandName"' => command_name.to_s.inspect)
    end

    def emit_reference_check(check)
      ident = rust_ident_field(check[:field])
      target_subs = { '"TmplTarget"' => check[:target_name].inspect, '"tmpl_heads"' => check[:heads].inspect }

      if check[:optional]
        Exemplar.render("reference_check_optional", target_subs.merge("tmpl_target_mod" => check[:target_mod], "tmpl_optional_field" => ident))
      else
        Exemplar.render("reference_check_required", target_subs.merge("tmpl_target_mod" => check[:target_mod], "tmpl_field" => ident))
      end
    end

    # `a[:chapter_mod]` — which top-level generated module (`meta`,
    # `embryonaut`, `governance`, ...) this aggregate's own .rs file
    # lives under (`domain_generator.rb`'s own header on why: `super::`
    # only resolves within the SAME directory, which stops being true
    # the moment aggregates from more than one chapter feed one merged
    # registry). `crate::generated::#{chapter_mod}::` is valid from
    # every caller of `emit_registry` — a single-chapter call (today's
    # per-domain `registry.rs`) and the merged multi-chapter one
    # (bin/project_rust's own new step) both resolve identically,
    # because a module can always name itself by its own absolute path.
    # `domain_name` is no longer a single shared param — `dump_arms`
    # reads `a[:domain_name]` PER aggregate instead (`domain_generator.
    # rb`'s own header on why: a merged multi-chapter registry would
    # otherwise mislabel every aggregate's own instance dump with
    # whichever ONE chapter name got passed in, e.g. every Governance/
    # Identity record showing up as "Embryonaut::whatever#id").
    def emit_registry(aggregates)
      chapter_path = ->(a) { "crate::generated::#{a[:chapter_mod]}::#{a[:mod]}" }
      store_fields = aggregates.map { |a| "    pub #{a[:mod]}: crate::kernel::InMemoryRepository<#{chapter_path.call(a)}::#{a[:record]}>," }
      store_inits  = aggregates.map { |a| "            #{a[:mod]}: crate::kernel::InMemoryRepository::new()," }

      dump_arms = aggregates.map do |a|
        prefix = "#{a[:domain_name]}::#{a[:name]}#"
        <<~RUST.rstrip
                  for (id, record) in self.#{a[:mod]}.entries() {
                      instances.push((format!("{}{}", #{prefix.inspect}, id), record.to_json()));
                  }
        RUST
      end

      # The mechanical inverse of `instances()` above, one `if let` per
      # aggregate trying its own "Domain::Aggregate#" prefix against
      # each seed key in turn — a key nothing here recognizes is
      # skipped, not refused (a seed built for a merged multi-chapter
      # Store, or reused loosely across a boundary this generator
      # doesn't fully control, shouldn't have to be exact). Exists for
      # `cli.rs`'s own new `"seed"` input field — a HOST (rust/host,
      # docs/decisions/0012) seeding prior state back in instead of
      # replaying full command history from scratch every invocation.
      seed_arms = aggregates.map do |a|
        mod_path = chapter_path.call(a)
        prefix = "#{a[:domain_name]}::#{a[:name]}#"
        <<~RUST.rstrip
                  if let Some(id) = key.strip_prefix(#{prefix.inspect}) {
                      store.#{a[:mod]}.save(id, #{mod_path}::#{a[:record]}::from_json(value)?);
                      continue;
                  }
        RUST
      end

      aggregate_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        a[:commands].map do |c|
          dispatch_call = "#{mod_path}::dispatch_#{c[:fn]}(&mut store.#{a[:mod]}, #{c[:creates] ? '' : '&id, '}args, mutations)"
          id_line = c[:creates] ? "" : "let id = #{mod_path}::#{a[:record]}::extract_id(args_json)?;"
          role_line = emit_role_check(c[:role], c[:name])
          reference_lines = c[:reference_checks].map { |check| emit_reference_check(check) }

          body = [id_line, "let args = #{mod_path}::#{c[:args_struct]}::from_json(args_json)?;", role_line, *reference_lines,
                  "let payload = crate::kernel::Json::overlay(args_json, &args.to_json());",
                  "#{dispatch_call}.map(|(_, events)| stamp_payload(events, &payload))"].compact.reject(&:empty?)

          "          #{c[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      # Entity commands never create — both the parent's identity and the
      # addressed element's own are always read off the raw JSON
      # (`extract_id` reused for both: an entity's own IR shape carries
      # `identified_by` the same way an aggregate's does — json_codec.rb's
      # `emit_extract_id` header). `commands.rb`'s `emit_entity_command`
      # names the generated function `dispatch_entity_<fn>` — the
      # `"entity_" + fn` this file's own `fn:` entries already carry.
      entity_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        a[:entity_commands].map do |c|
          role_line = emit_role_check(c[:role], c[:name])
          reference_lines = c[:reference_checks].map { |check| emit_reference_check(check) }
          dispatch_call = "#{mod_path}::dispatch_entity_#{c[:fn]}(&mut store.#{a[:mod]}, &parent_id, &element_id, args, mutations).map(|(_, events)| stamp_payload(events, &payload))"

          body = ["let parent_id = #{mod_path}::#{a[:record]}::extract_id(args_json)?;",
                  "let element_id = #{mod_path}::#{c[:entity_record]}::extract_id(args_json)?;",
                  "let args = #{mod_path}::#{c[:args_struct]}::from_json(args_json)?;",
                  role_line, *reference_lines,
                  "let payload = crate::kernel::Json::overlay(args_json, &args.to_json());",
                  dispatch_call].compact

          "          #{c[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      dispatch_arms = aggregate_arms + entity_arms

      header = <<~RUST
        // GENERATED by bin/project_rust — the JSON command router
        // `kernel::cli` dispatches every step through. Do not hand-edit —
        // re-run bin/project_rust instead.
        #![allow(dead_code, unused_variables)]

        // `Repository::save` (from_seed, below) is a TRAIT method —
        // `InMemoryRepository`'s own inherent methods (entries(), used
        // by instances()) need no import, but save() does.
        use crate::kernel::Repository;

      RUST

      body = Exemplar.render(
        "registry_file",
        "TmplStore2" => "Store",
        "    pub tmpl_field: crate::kernel::InMemoryRepository<i64>," => store_fields.join("\n"),
        "            tmpl_field: tmpl_store_fields_placeholder()," => store_inits.join("\n"),
        "tmpl_dump_arm_placeholder();" => dump_arms.join("\n"),
        "tmpl_seed_arm_placeholder();" => seed_arms.join("\n"),
        '"tmpl_verb" => { tmpl_dispatch_arm_placeholder() }' => dispatch_arms.join("\n")
      )

      "#{header}#{body}"
    end
  end
end

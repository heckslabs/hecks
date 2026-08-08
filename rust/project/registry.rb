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
    # args_struct:, creates:, reference_checks:}], entity_commands: [{verb:,
    # entity_record:, fn:, args_struct:, reference_checks:}]}]` —
    # accumulated by domain_generator.rb while it walks the real IR, not
    # re-derived here. `reference_checks` is `[{field:, optional:,
    # target_mod:, target_name:, heads:}]` (`domain_generator.rb`'s own
    # `reference_checks` helper) — `CommandRules::References
    # #resolve_references`'s per-attribute walk, done at codegen time
    # instead of dispatch time.
    #
    # Emitted HERE, in the router, rather than inside each command's own
    # `dispatch_*` function (commands.rb): `store` — every OTHER aggregate's
    # repo, not just this command's own — only exists at this level, the
    # same way Ruby's own version reaches through `@registry.repository
    # (domain, target)` rather than anything local to one command. Emitted
    # right after `from_json` succeeds and before the real dispatch call,
    # matching Ruby's own `DISPATCH_ORDER`: `resolve_references` runs after
    # argument normalization/coercion, strictly before `hydrate`/
    # `enforce_givens` — verified live (0016's own investigation): a
    # dangling reference is refused before the command's OWN `given`s are
    # even consulted.
    def emit_reference_check(check)
      ident = rust_ident_field(check[:field])
      call = "crate::kernel::check_reference(&store.#{check[:target_mod]}, #{check[:optional] ? 'v' : "&args.#{ident}"}, #{check[:target_name].inspect}, #{check[:heads].inspect})?;"
      check[:optional] ? "if let Some(v) = &args.#{ident} { #{call} }" : call
    end

    def emit_registry(domain_name, aggregates)
      store_fields = aggregates.map { |a| "    pub #{a[:mod]}: crate::kernel::InMemoryRepository<super::#{a[:mod]}::#{a[:record]}>," }
      store_inits  = aggregates.map { |a| "            #{a[:mod]}: crate::kernel::InMemoryRepository::new()," }

      dump_arms = aggregates.map do |a|
        prefix = "#{domain_name}::#{a[:name]}#"
        <<~RUST.rstrip
                  for (id, record) in self.#{a[:mod]}.entries() {
                      instances.push((format!("{}{}", #{prefix.inspect}, id), record.to_json()));
                  }
        RUST
      end

      aggregate_arms = aggregates.flat_map do |a|
        a[:commands].map do |c|
          dispatch_call = "super::#{a[:mod]}::dispatch_#{c[:fn]}(&mut store.#{a[:mod]}, #{c[:creates] ? '' : '&id, '}args)"
          id_line = c[:creates] ? "" : "let id = super::#{a[:mod]}::#{a[:record]}::extract_id(args_json)?;"
          reference_lines = c[:reference_checks].map { |check| emit_reference_check(check) }

          body = [id_line, "let args = super::#{a[:mod]}::#{c[:args_struct]}::from_json(args_json)?;", *reference_lines,
                  "#{dispatch_call}.map(|(_, events)| stamp_payload(events, args_json))"].reject(&:empty?)

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
        a[:entity_commands].map do |c|
          reference_lines = c[:reference_checks].map { |check| emit_reference_check(check) }
          dispatch_call = "super::#{a[:mod]}::dispatch_entity_#{c[:fn]}(&mut store.#{a[:mod]}, &parent_id, &element_id, args).map(|(_, events)| stamp_payload(events, args_json))"

          body = ["let parent_id = super::#{a[:mod]}::#{a[:record]}::extract_id(args_json)?;",
                  "let element_id = super::#{a[:mod]}::#{c[:entity_record]}::extract_id(args_json)?;",
                  "let args = super::#{a[:mod]}::#{c[:args_struct]}::from_json(args_json)?;",
                  *reference_lines, dispatch_call]

          "          #{c[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      dispatch_arms = aggregate_arms + entity_arms

      <<~RUST
        // GENERATED by bin/project_rust — the JSON command router
        // `kernel::cli` dispatches every step through. Do not hand-edit —
        // re-run bin/project_rust instead.
        #![allow(dead_code, unused_variables)]

        pub struct Store {
        #{store_fields.join("\n")}
        }

        impl Store {
            pub fn new() -> Self {
                Self {
        #{store_inits.join("\n")}
                }
            }

            /// Every aggregate this domain declared, dumped as
            /// "Domain::Aggregate#id" -> its own to_json() — the exact key
            /// shape bin/rust_conformance's own comparable["instances"]
            /// builds from Ruby (Fuzzing::Replay.call's own instance key
            /// format, read directly).
            pub fn instances(&self) -> Vec<(String, crate::kernel::Json)> {
                let mut instances = Vec::new();
        #{dump_arms.join("\n")}
                instances
            }
        }

        pub fn dispatch_by_name(
            store: &mut Store,
            verb: &str,
            args_json: &crate::kernel::Json,
        ) -> Result<Vec<crate::kernel::Event>, crate::kernel::Refusal> {
            match verb {
        #{dispatch_arms.join("\n")}
                other => Err(crate::kernel::Refusal::TypeMismatch(format!("unknown command {other:?}"))),
            }
        }

        /// Ruby's own event payload is `payload: args` — the WHOLE hash the
        /// caller passed to `dispatch`, not filtered to the command's own
        /// declared attributes (an identity-reference argument like
        /// `number:` is not a declared `CreditArgs` field, and still shows
        /// up on `AccountCredited`'s payload). `args.to_json()` inside each
        /// generated `dispatch_*` only ever sees the NARROWED, typed args
        /// struct, so it structurally can't reproduce that — this replaces
        /// whatever payload the generated dispatch built with the raw,
        /// unfiltered `args_json` this router itself received, after the
        /// fact, once dispatch has already decided whether to accept it.
        /// Load-bearing for process managers, not just payload fidelity: a
        /// saga leg that forwards `reference: :reference` into `Account.
        /// Debit` (which doesn't declare a `reference` attribute) needs
        /// that field to survive onto `AccountDebited`'s own payload for
        /// `correlates_by` to find it downstream.
        fn stamp_payload(events: Vec<crate::kernel::Event>, args_json: &crate::kernel::Json) -> Vec<crate::kernel::Event> {
            events.into_iter().map(|e| crate::kernel::Event { payload: args_json.clone(), ..e }).collect()
        }
      RUST
    end
  end
end

module RustProjection
  module Projector
    module_function

    # `Policy#event_qualifier`/`#event_name` (`Naming.qualifier`/
    # `Naming.unqualified`, read directly) — NOT separate wire fields
    # (`Policy#to_h` only carries `on_event` whole); the exported
    # canonical IR gives this generator the same raw `on_event` string
    # Ruby's own runtime re-derives these from, so it re-derives them the
    # identical way rather than exporting a fourth field the wire contract
    # doesn't have.
    def policy_event_qualifier(on_event)
      text = on_event.to_s
      text.include?(".") ? text.split(".", 2).first : nil
    end

    def policy_event_name(on_event)
      text = on_event.to_s
      text.include?(".") ? text.split(".", 2).last : text
    end

    # ── THE POLICY TABLE — `kernel::orchestrate`'s own static data,
    # `Runtime::PolicyInterpreter#policies_for`/`#deliver` ported to
    # generated `PolicyRule` rows a hand-written, generic function walks
    # (kernel/orchestrate.rs), the SAME "compile shapes, interpret
    # behavior" split every other generated/kernel pair in this project
    # already holds to.
    #
    # CROSS-DOMAIN POLICIES ARE SPLIT OUT, not skipped: `bin/project_rust
    # <domain>` still compiles exactly ONE target domain (plus the
    # self-hosted meta-language) into one `Store` — a policy whose
    # `across` names a domain THIS build never generated still has no
    # `dispatch_by_name`/`Store` to route to LOCALLY. What changed is
    # that local dispatch is no longer the only way this project delivers
    # a command: `rust/host` (the unsandboxed host layer, real AWS SDK
    # access this WASM-compiled kernel structurally lacks — see
    # orchestrate.rs's own header) can invoke that OTHER domain's own
    # deployed Lambda directly, a straight port of Ruby's own
    # `Adapters::Lambda::Client`. `emit_cross_domain_policy_table`, below,
    # emits these rows into their OWN table (`CrossDomainPolicyRule`, not
    # `PolicyRule` — a different shape, since there is no local
    # `target_verb` to dispatch, only a domain+verb pair for rust/host's
    # `lambda_client.rs` to invoke remotely) instead of dropping them.
    def emit_policy_table(domain_name, policies, aggregates = [])
      fns  = where_fns(policies)
      rows = local_policy_rows(domain_name, policies, aggregates)

      Exemplar.render(
        "policy_table",
        'crate::kernel::PolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_verb: "tmpl_target_verb", for_each: None, for_each_key: None, with_spec: &[], where_expr: None },' => rows.join("\n")
      ).then { |table| fns.empty? ? table : "#{table}\n\n#{fns.join("\n\n")}" }
    end

    # ── THE MERGED POLICY TABLE — bin/project_rust's own `merged.rs`,
    # spanning the target domain AND every framework/vendored chapter it
    # attaches, the SAME union `merged_aggregates`/`merged_queries` there
    # already are. RECOVERS A DOCUMENTED, DELIBERATE GAP: bin/project_rust
    # used to call `emit_policy_table` with ONLY the target domain's own
    # policies — "Policies/process managers do NOT merge across chapters
    # here — Governance/Identity declare none today... not attempted by
    # this pass" (that comment's own words). Governance/Identity really
    # don't declare any, so the gap was invisible until a domain vendored
    # a chapter that DOES — found live, generating lifeadelics' vendored
    # embryonaut_bluebooks/payments: `Payments::Payment.PaymentGateway
    # .Succeeded` (a real, generated, correctly-dispatchable port
    # operation — dispatch_by_name already routes it fine) emitted
    # `PaymentConfirmedByProcessor` exactly as declared, but the MERGED
    # Store's own POLICIES table was `&[]` — Payments' 8 policies existed
    # in payments/registry.rs's own STANDALONE table (each chapter still
    # gets its own, unchanged, via emit_policy_table above), just never
    # folded into the ONE table kernel::orchestrate actually reads at
    # runtime. `OnPaymentConfirmedByProcessor`'s own trigger never fired;
    # a real webhook would have left the payment stuck "pending" forever.
    #
    # `sources` — one `{domain_name:, policies:, aggregates:}` per
    # chapter (target first, then each attached one, matching
    # `chapter_mod_names`' own insertion order) — each entry runs through
    # the IDENTICAL `local_policy_rows` a standalone chapter's own table
    # already uses, so a policy's own `target_verb` is qualified against
    # ITS OWN domain_name/aggregates, never the target's.
    def emit_merged_policy_table(sources)
      rows = sources.flat_map { |source| local_policy_rows(source[:domain_name], source[:policies], source[:aggregates]) }
      fns  = sources.flat_map { |source| where_fns(source[:policies]) }

      Exemplar.render(
        "policy_table",
        'crate::kernel::PolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_verb: "tmpl_target_verb", for_each: None, for_each_key: None, with_spec: &[], where_expr: None },' => rows.join("\n")
      ).then { |table| fns.empty? ? table : "#{table}\n\n#{fns.join("\n\n")}" }
    end

    def local_policy_rows(domain_name, policies, aggregates = [])
      policies.filter_map do |policy|
        target_domain = policy[:target_domain] || domain_name
        next nil unless target_domain == domain_name

        event_name = policy_event_name(policy[:on_event])
        qualifier = policy_event_qualifier(policy[:on_event])
        qualifier_expr = qualifier ? "Some(#{qualifier.inspect})" : "None"
        target_verb = "#{target_domain}::#{policy[:trigger_command]}"

        # `policy_name` — orchestrate.rs's own `reaction_log`/`saga_log`
        # entries need the policy's own declared name (`PolicyInterpreter
        # #deliver`'s `record = { policy: policy.name, ... }`, read
        # directly) — previously absent here on purpose (this struct's own
        # OLD header: "nothing downstream of a same-domain reaction ever
        # needed to name the policy that caused it"), now needed the same
        # way `CrossDomainPolicyRule` already carries it.
        "    crate::kernel::PolicyRule { policy_name: #{policy[:name].to_s.inspect}, event_name: #{event_name.inspect}, " \
          "event_qualifier: #{qualifier_expr}, target_verb: #{target_verb.inspect}, " \
          "for_each: #{fan_out_verb_expr(domain_name, policy)}, " \
          "for_each_key: #{fan_out_key_expr(domain_name, policy, aggregates)}, " \
          "with_spec: #{with_spec_expr(policy)}, where_expr: #{where_expr(policy)} },"
      end
    end

    # `where { … }` — the policy's own predicate over the event payload
    # (`PolicyInterpreter#where_holds?`). A `PolicyRule` is a `const` row,
    # and an `Expr` owns boxes, so the predicate is a generated FUNCTION
    # the kernel calls when the event arrives — `where_expr: Some(fn)` in
    # the row, the fn itself emitted beside the table (`where_fns`).
    def where_fn_name(policy) = "where_#{dispatch_fn_name(rust_ident(policy[:name].to_s))}"

    def where_expr(policy)
      policy[:where].to_s.empty? ? "None" : "Some(#{where_fn_name(policy)})"
    end

    def where_fns(policies)
      policies.reject { |policy| policy[:where].to_s.empty? }.map do |policy|
        "fn #{where_fn_name(policy)}() -> crate::kernel::Expr {\n" \
          "    use crate::kernel::Expr;\n" \
          "    #{ExprEmitter.emit_predicate(policy[:where])}\n" \
          "}"
      end
    end


    # ── `for_each` — THE FAN-OUT'S OWN QUERY, qualified here rather than
    # in the kernel. `Behaviour::Policy#for_each_route` resolves the bare
    # "Aggregate.query" spelling against the policy's OWN domain, and
    # that resolution is a fact about the source: settling it at codegen
    # keeps the kernel's own lookup a plain table hit, the same shape
    # `cli::run` already answers a top-level ask with.
    def fan_out_verb_expr(domain_name, policy)
      for_each = policy[:for_each].to_s
      return "None" if for_each.empty?

      "Some(#{(for_each.include?("::") ? for_each : "#{domain_name}::#{for_each}").inspect})"
    end

    # ── THE NAME A MATCHED ROW'S ID IS MINTED UNDER, which is the TARGET
    # COMMAND'S question and not the aggregate's: a command declared ON
    # the aggregate it references is addressed by that aggregate's own
    # bare reference key, and one merely HOLDING a reference to it is
    # addressed by the attribute that holds it. `Behaviour::Command
    # #addressing_key_for` is the rule, and this is the same rule read
    # off the exported IR — `spec/codegen_parity_spec.rb` holds this
    # generator byte-identical to `rust/codegen`'s own twin, which is
    # what keeps the two spellings of it from drifting.
    def fan_out_key_expr(domain_name, policy, aggregates)
      for_each = policy[:for_each].to_s
      return "None" if for_each.empty?

      path, = for_each.split(".", 2)
      row_aggregate = path.to_s.include?("::") ? path.split("::", 2).last : path
      command = target_command_for(policy, aggregates)
      key = command && addressing_key_for(command, row_aggregate)
      key ? "Some(#{key.to_s.inspect})" : "None"
    end

    def target_command_for(policy, aggregates)
      aggregate_name, command_name = policy[:trigger_command].to_s.split(".", 2)
      aggregate = Array(aggregates).find { |candidate| candidate[:name].to_s == aggregate_name.to_s }
      Array(aggregate && aggregate[:commands]).find { |candidate| candidate[:name].to_s == command_name.to_s }
    end

    def addressing_key_for(command, aggregate_name)
      return snake_case(aggregate_name) if command[:references].to_s == aggregate_name.to_s

      held = Array(command[:attributes]).find { |attribute| attribute[:type].to_s == "Reference<#{aggregate_name}>" }
      held && held[:name]
    end

    def snake_case(name)
      name.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2').downcase
    end

    # ── `trigger ..., with:` — WHAT THE TRIGGER IS GIVEN. Each binding
    # rides the wire already rendered (`Literal::render`, so a Symbol
    # keeps its leading colon and stays distinguishable from a literal
    # string of the same spelling); the kernel reads that spelling back.
    def with_spec_expr(policy)
      pairs = Array(policy[:with_spec])
      return "&[]" if pairs.empty?

      "&[#{pairs.map { |key, value| "(#{key.to_s.inspect}, #{value.to_s.inspect})" }.join(', ')}]"
    end

    # ── THE CROSS-DOMAIN POLICY TABLE — every policy `local_policy_rows`
    # above filtered OUT, represented instead of dropped. `target_verb`
    # here is FULLY QUALIFIED (`"#{target_domain}::#{trigger_command}"`),
    # the SAME formula `local_policy_rows` uses, above — NOT the bare
    # `policy[:trigger_command]` this used to emit.
    #
    # FOUND LIVE, deploying a real second domain (Compliance) to actually
    # prove cross-domain delivery for the first time: a bare verb refuses
    # with "unknown command" against ANY compiled target, single-chapter
    # or not — `dispatch_by_name`'s own generated match arms are ALWAYS
    # "Domain::Aggregate.Command", the same convention every other verb
    # in this whole system already uses (`kernel::cli::run`'s own
    # top-level step, `RemoteDispatcher#dispatch`'s real cross-Lambda
    # calls, `Adapters::Lambda::Client#dispatch`). The OLD reasoning here
    # ("the Lambda invoked IS the domain, so the verb it receives is
    # already implicitly scoped to it") assumed a target Lambda's own
    # dispatch table could somehow be UNqualified for a single-chapter
    # compile — never actually true; nothing in `rust/project/registry.rb`
    # ever emits an unqualified match arm. Confirmed both ways: compiled
    # `examples/compliance` refuses a bare "AccountFreezeReview.Open" as
    # "unknown command" and accepts "Compliance::AccountFreezeReview.Open"
    # cleanly. This was never caught before because no domain had ever
    # deployed a real second Lambda to receive one of these calls.
    def cross_domain_policy_rows(domain_name, policies)
      policies.filter_map do |policy|
        target_domain = policy[:target_domain] || domain_name
        next nil if target_domain == domain_name

        event_name = policy_event_name(policy[:on_event])
        qualifier = policy_event_qualifier(policy[:on_event])
        qualifier_expr = qualifier ? "Some(#{qualifier.inspect})" : "None"
        target_verb = "#{target_domain}::#{policy[:trigger_command]}"

        "    crate::kernel::CrossDomainPolicyRule { policy_name: #{policy[:name].to_s.inspect}, event_name: #{event_name.inspect}, " \
          "event_qualifier: #{qualifier_expr}, target_domain: #{target_domain.inspect}, target_verb: #{target_verb.inspect}, " \
          "where_expr: #{where_expr(policy)} },"
      end
    end

    def emit_cross_domain_policy_table(domain_name, policies)
      rows = cross_domain_policy_rows(domain_name, policies)

      puts "cross-domain policy table: #{rows.size} row(s) — delivered by rust/host's lambda_client.rs, not locally dispatched" if rows.any?

      Exemplar.render(
        "cross_domain_policy_table",
        'crate::kernel::CrossDomainPolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_domain: "tmpl_target_domain", target_verb: "tmpl_target_verb", where_expr: None },' =>
          rows.join("\n")
      )
    end

    # ── THE MERGED CROSS-DOMAIN POLICY TABLE — same recovery as
    # emit_merged_policy_table above, same documented gap, same reason
    # (Governance/Identity declare no cross-domain policies either, so
    # this half was equally invisible until a vendored chapter needed
    # it). `sources` — the identical `{domain_name:, policies:,
    # aggregates:}` array `emit_merged_policy_table` takes (aggregates
    # unused here, cross-domain rows need no fan-out addressing key —
    # see cross_domain_policy_rows' own shape).
    def emit_merged_cross_domain_policy_table(sources)
      rows = sources.flat_map { |source| cross_domain_policy_rows(source[:domain_name], source[:policies]) }

      puts "cross-domain policy table: #{rows.size} row(s) — delivered by rust/host's lambda_client.rs, not locally dispatched" if rows.any?

      Exemplar.render(
        "cross_domain_policy_table",
        'crate::kernel::CrossDomainPolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_domain: "tmpl_target_domain", target_verb: "tmpl_target_verb", where_expr: None },' =>
          rows.join("\n")
      )
    end

    # A `with:` binding's raw wire spelling — Hecks::Literal's, the
    # same one every other to_h-bound literal field rides. `Marks.read` is
    # the exact, already-proven inverse (mutations.rb's
    # `append_field_source` is the identical round trip on a `sets
    # append:` field) — reused rather than re-derived.
    def with_value_parsed(raw)
      Hecks::Bluebook::Assembly::Marks.read(raw)
    end

    # A parsed `with:` literal (`Marks.read`'s own output shape for
    # anything that isn't a Symbol — a Hash/String/Integer/Float/Boolean/
    # nil) to a Rust expression BUILDING the equivalent `Json` value —
    # never a `const` literal (`Json` holds `Vec`/`String`, not
    # `const`-constructible in stable Rust), which is why every literal
    # gets its own one-off generated function (`emit_with_value`, below).
    def json_literal_expr(value)
      case value
      when Hash
        fields = value.map { |k, v| "(#{k.to_s.inspect}.to_string(), #{json_literal_expr(v)})" }
        "crate::kernel::Json::Object(vec![#{fields.join(', ')}])"
      when String
        "crate::kernel::Json::Str(#{value.inspect}.to_string())"
      when Integer
        "crate::kernel::Json::int(#{value})"
      when Float
        "crate::kernel::Json::Num(#{value}f64)"
      when true, false
        "crate::kernel::Json::Bool(#{value})"
      when nil
        "crate::kernel::Json::Null"
      else
        raise "unsupported with: literal #{value.inspect} — json_literal_expr doesn't cover this shape"
      end
    end

    # One `with:` binding, resolved to a `WithValue` — a bare Symbol is a
    # RUNTIME reference (`WithValue::Ref`, resolved by
    # `kernel::orchestrate`'s `resolve_with`); anything else is a LITERAL,
    # emitted as its own tiny `fn() -> Json` (`literal_fns` collects these
    # so the caller can splice them in above the table that references
    # them by name).
    def emit_with_value(raw, literal_fns)
      parsed = with_value_parsed(raw)
      return "crate::kernel::WithValue::Ref(#{parsed.to_s.inspect})" if parsed.is_a?(Symbol)

      fn_name = "pm_literal_#{literal_fns.size}"
      literal_fns << Exemplar.render(
        "with_value_literal_fn",
        "tmpl_literal_fn" => fn_name,
        "tmpl_body_placeholder()" => json_literal_expr(parsed)
      )
      "crate::kernel::WithValue::Literal(#{fn_name})"
    end

    # `compensates` — per-dispatch saga compensation (`ir::DispatchSpec::
    # compensates`/`Hecks::Bluebook::DispatchSpec#compensates`,
    # `lib/hecks/bluebook/process_manager.rb`): `nil` on the IR emits
    # `None`; a nested hash recurses through THIS SAME method one level
    # in — the identical move `kernel::orchestrate::DispatchSpec::
    # compensates`'s own header describes for why it's `Option<&'static
    # DispatchSpec>`, not `Option<Box<DispatchSpec>>` — `Some(&...)`
    # here relies on Rust's rvalue static promotion (a struct literal
    # built entirely of other promotable/`'static` values promotes to
    # a `'static` place a reference can point at) inside the `static`
    # table this whole expression is spliced into. Never nested further
    # than one level on the Ruby side (a compensation is not itself
    # compensable), so this recursion bottoms out in at most one extra
    # call.
    def emit_dispatch_spec(spec, literal_fns)
      with_pairs = spec[:with_spec].map { |key, raw| "(#{key.to_s.inspect}, #{emit_with_value(raw, literal_fns)})" }
      compensates = spec[:compensates] ? "Some(&#{emit_dispatch_spec(spec[:compensates], literal_fns)})" : "None"
      "crate::kernel::DispatchSpec { command_name: #{spec[:command_name].inspect}, with: &[#{with_pairs.join(', ')}], compensates: #{compensates} }"
    end

    def emit_handler(handler, literal_fns)
      dispatches = handler[:dispatches].map { |d| emit_dispatch_spec(d, literal_fns) }
      "crate::kernel::Handler { event_type: #{handler[:event_type].inspect}, from_state: #{handler[:from_state].inspect}, to_state: #{handler[:to_state].inspect}, dispatches: &[#{dispatches.join(', ')}] }"
    end

    # ── THE PROCESS MANAGER TABLE — `kernel::orchestrate`'s own static
    # data for `SagaInterpreter#advance`/`#unwind`, the same "compile
    # shapes, interpret behavior" split the policy table above holds to.
    # No cross-domain narrowing needed here the way `emit_policy_table`
    # needs one: every `dispatch` spec's `command_name` is ALREADY fully
    # domain-qualified on the wire (`Banking::Account.Debit`, not
    # `Account.Debit`) — a process manager cannot name a target this
    # single-domain `Store` doesn't hold without that verb simply failing
    # to route at `dispatch_by_name`'s own `unknown command` branch, the
    # same swallowed-refusal path any other unreachable target takes.
    def emit_process_manager_table(process_managers)
      literal_fns = []
      pm_exprs = process_managers.map do |pm|
        handlers = pm[:handlers].map { |h| emit_handler(h, literal_fns) }
        "crate::kernel::ProcessManagerDef { name: #{pm[:name].inspect}, correlates_by: #{pm[:correlates_by].inspect}, " \
          "starts_on: #{pm[:starts_on].inspect}, ends_on: #{pm[:ends_on].inspect}, initial_state: #{pm[:states].first.inspect}, " \
          "handlers: &[#{handlers.join(', ')}] }"
      end

      Exemplar.render(
        "process_manager_table",
        "fn tmpl_literal_fns_placeholder() {}" => literal_fns.join("\n"),
        '    crate::kernel::ProcessManagerDef { name: "tmpl_pm_name", correlates_by: "tmpl_correlates_by", starts_on: "tmpl_starts_on", ends_on: "tmpl_ends_on", initial_state: "tmpl_initial_state", handlers: &[] },' =>
          pm_exprs.map { |e| "    #{e}," }.join("\n")
      )
    end

    # `Naming.reference_key(event.aggregate)`, precomputed per aggregate
    # rather than re-derived at runtime — `Correlation#saga_correlation`'s
    # own THIRD tier (this file's own header on `orchestrate.rs`), needed
    # for real: a leg dispatched WITH its own `reference_to` argument
    # (`Transfer.Credited`'s own `transfer:`, `json_codec.rb`'s
    # `emit_extract_id` header) announces an event whose payload carries
    # THAT key, not `correlates_by`'s own dotted field — `TransferCredited`
    # only ever has `{"transfer": "xfer-1"}`, never `{"reference": {...}}`.
    # `kernel::orchestrate`'s `correlation_of` falls back to this table,
    # keyed by the emitting event's OWN qualified aggregate name, exactly
    # the same per-event (not per-process-manager) rule Ruby's own
    # `Naming.reference_key(event.aggregate)` applies.
    # `chapters` — `[[domain_name, aggregate_names], ...]`, one pair per
    # chapter (bin/project_rust's own per-domain call for a single-
    # chapter registry.rs passes exactly one pair; the merged registry
    # spanning every chapter a domain attaches passes one pair per
    # chapter) — this table is domain-qualified-name -> key regardless
    # of how many chapters fed it, so merging is just "more pairs in
    # the same flat list," no other change needed.
    def emit_reference_key_table(chapters)
      arms = chapters.flat_map do |domain_name, aggregate_names|
        aggregate_names.map do |name|
          qualified = "#{domain_name}::#{name}"
          key = Hecks::Naming.snake(name)
          "        #{qualified.inspect} => Some(#{key.inspect}),"
        end
      end

      Exemplar.render("reference_key_table", '"tmpl_qualified" => Some("tmpl_key"),' => arms.join("\n"))
    end

    # ── "DOES THIS VERB CREATE THE RECORD IT ADDRESSES" — `orchestrate.rs`'s
    # own routing split (`split_routed_args`, its own header) needs this
    # BEFORE it can decide whether a policy/saga-triggered dispatch's
    # projected args should have their addressing key promoted into `to:`
    # at all: `ReactionInvocation.build`'s own `target.command.creates?`
    # gate — a CREATING target has no existing record to route to, so its
    # whole projection stays `with:` facts, unrouted, exactly like
    # `Pizzas::Order.CreatePizza` dispatched directly. Reuses `emit_
    # registry`'s own already-computed `commands[]`/`entity_commands[]`
    # `creates:`/`verb:` fields verbatim — an entity command is never
    # creating (commands.rb's own header on `emit_entity_command`), so it
    # always reads `false` here without needing its own separate branch.
    def emit_creates_table(aggregates)
      arms = aggregates.flat_map do |aggregate|
        (Array(aggregate[:commands]).map { |c| [c[:verb], c[:creates]] } +
         Array(aggregate[:entity_commands]).map { |c| [c[:verb], false] }).map do |verb, creates|
          "        #{verb.inspect} => #{creates},"
        end
      end

      Exemplar.render("creates_table", '"tmpl_verb" => true,' => arms.join("\n"))
    end

    # ── THE SINGLE-COMPONENT IDENTITY HEAD `orchestrate.rs`'s own routing
    # split (`split_routed_args`) tries FIRST, matching `ReactionInvocation
    # .identity_for`'s own first move (`Identity.of`, tried before any
    # alias): a construct's own declared identity field, present in the
    # projected args by that EXACT name — `ExternalTransfer::SendTransfer`'s
    # own `dispatch ..., with: { end_to_end: :end_to_end }` is the corpus's
    # live example (`end_to_end`, `ExternalTransfer`'s own `identified_by`
    # head, not derivable from `reference_key_for_aggregate`'s generic
    # snake-cased-type-name rule at all). A COMPOSITE identity (more than
    # one component) is a real, documented gap here, not silently assumed
    # to work — `identity_for`'s own multi-field reconstruction needs every
    # component present at once, which this single-key table cannot
    # express; skipped rather than guessed at.
    def emit_identity_head_table(aggregates)
      arms = aggregates.filter_map do |aggregate|
        heads = Array(aggregate[:identified_by])
        next if heads.size != 1

        head = heads.first.to_s.split(".").first
        qualified = "#{aggregate[:domain_name]}::#{aggregate[:name]}"
        "        #{qualified.inspect} => Some(#{head.inspect}),"
      end

      Exemplar.render("identity_head_table", '"tmpl_qualified" => Some("tmpl_head"),' => arms.join("\n"))
    end

    # ── THIS COMMAND'S OWN DECLARED ATTRIBUTE NAMES (R1,
    # docs/audits/2026-08-11-bug-triage.md) — `orchestrate.rs`'s own
    # `split_routed_args` needs this to build a reaction-triggered
    # dispatch's `with:` facts the SAME way `ReactionInvocation.
    # command_facts` does on the Ruby side: `args.slice(*declared)`,
    # dropping anything the target command doesn't itself declare as an
    # attribute — an identity/reference/correlation key a policy or
    # process manager's own `with:` mapping resolved (`reference: :reference`
    # forwarding a Transfer's own reference onto its saga-dispatched
    # Account::Debit/Credit legs, the corpus's real, live example) but
    # the TARGET command never declared stays OFF that command's own
    # event payload — exactly like a direct, hand-written dispatch of the
    # same command never carries it either. Previously `split_routed_
    # args` only ever REMOVED the one key it promoted into `to:`,
    # leaving every OTHER undeclared key (like a forwarded `reference:`)
    # sitting in `with:` unfiltered, which is what let it leak all the
    # way into the persisted event (`Json::overlay`'s own `patch` merge
    # never touches a key it doesn't declare, so `base`'s copy — this
    # exact leaked key — survived the merge untouched).
    #
    # Built the same way `emit_creates_table` is: one arm per verb, both
    # `aggregate[:commands]` and `aggregate[:entity_commands]` — an
    # entity command's own declared attributes are exactly as real a
    # constraint on its facts as an aggregate command's.
    #
    # NARROWER THAN Ruby's OWN gate, on purpose: this only ever runs
    # inside `split_routed_args`, itself only ever reached from a
    # POLICY/PROCESS-MANAGER-triggered dispatch (`react_policies`/
    # `deliver_saga_dispatch`'s own `build_dispatch_args`) — a direct,
    # externally-dispatched command's own facts are never touched by
    # this table at all, matching Ruby's own split (`ReactionInvocation
    # .build`'s `command_facts` slice applies to a REACTION's own
    # explicit projection, never to `Dispatcher#dispatch`'s plain
    # external args).
    def emit_command_attributes_table(aggregates)
      arms = aggregates.flat_map do |aggregate|
        (Array(aggregate[:commands]) + Array(aggregate[:entity_commands])).map do |c|
          names = Array(c[:attributes]).map { |name| name.to_s.inspect }.join(", ")
          "        #{c[:verb].inspect} => &[#{names}],"
        end
      end

      Exemplar.render("command_attributes_table", '"tmpl_verb" => &["tmpl_attr"],' => arms.join("\n"))
    end
  end
end

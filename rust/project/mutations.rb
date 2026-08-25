module RustProjection
  module Projector
    module_function

    # A list-typed aggregate attribute reads `nil` in Ruby, not `[]`,
    # under one precise condition (0019's/0014's own investigation, read
    # directly against `mutation_applier.rb`/`value/coercion.rb`, not
    # guessed): some CREATING command declares an explicit `:set`-op
    # mutation (`sets attr, to: source`) targeting it, sourced from a
    # command argument the CALLER omitted. Every declared mutation runs
    # UNCONDITIONALLY during `apply_mutations` — `resolve_source`/`Value.
    # for_attribute` pass a missing argument through as a real `nil`,
    # overwriting `Instance.defaults`' own `[]` baseline every list
    # attribute otherwise starts with. `CardPayment.tags` (`sets
    # :tags, to: :tags`, sourced from its own `optional: true` argument)
    # is the corpus's one live example; `Account.ledger` (touched only by
    # `Credit`/`Debit`'s own `append`, never a creating command's `:set`)
    # is the negative case that must stay `[]` — the exact regression the
    # 0014 doc's own reverted empty-list-to-null heuristic caused by not
    # distinguishing them.
    def list_attr_creation_optional?(aggregate, attr_name, value_objects_by_name)
      aggregate[:commands].any? do |command|
        next false unless creates_owner?(aggregate, command, value_objects_by_name)

        command[:mutations].any? do |m|
          next false unless m[:op].to_s == "set" && m[:target].to_s == attr_name.to_s && m[:source][:kind] == "argument"

          source_attr = command[:attributes].find { |a| a[:name].to_s == m[:source][:name].to_s }
          source_attr && source_attr[:optional]
        end
      end
    end

    # `creates_owner?(aggregate, command, value_objects_by_name)` — REPLACES
    # `command[:references].nil?` ALONE (and the coincidental bare-name
    # matching `identity_components`, below, used to do) as the "does this
    # command build the OWNER record from scratch" test.
    #
    # `references.nil?` IS HONEST WHENEVER IT'S SET — a command that
    # genuinely declares `reference_to <its own owner>` (bare, no `as:`)
    # really does act on an existing one (`Compliance::AccountFreezeReview
    # .Clear`/`Governance::RoleTransition.Revoke`, both real, both keep
    # `references` non-nil and stay `false` here, unconditionally, on that
    # signal alone). What's dishonest is treating an ABSENT `references` as
    # proof of creation — a mutating meta-domain command like `Aggregate.
    # Attribute` declares no `reference_to` at all, not because it creates,
    # but because the owner it acts on is supplied entirely through ROUTING
    # (`to:`/`with:`), never as a declared argument — adding a bare
    # `reference_to Aggregate` purely to flip this heuristic was the
    # rejected direction (RESTART.md's own "Option 1": a fake self-
    # reference). So `references: nil` needs a SECOND, honest test.
    #
    # THAT TEST IS NOT COMPLETENESS. A creating command's generated Rust
    # struct Option-wraps EVERY scalar field regardless (`emit_record`'s own
    # header, types.rb) — an uncovered field just becomes `None`, which is
    # exactly how `Pizzas::Order.CreatePizza` (zero mutations, no `customer_
    # name` argument at all — `Order`'s fourth field) already generates
    # correctly. `Runtime::DependencyPlanning::Analyzer#complete_state?`
    # answers a DIFFERENT, narrower question for Ruby's own runtime (an
    # atomic-put OPTIMIZATION eligibility check) and disagrees with "creates"
    # on both sides — `CardPayment.Authorize` is complete_state?-false (its
    # own identity field, `authorisation`, is never a `:set` target) yet
    # unquestionably creates a fresh `CardPayment`; `Aggregate.Lifecycle`
    # IS complete_state?-true-shaped (it `:set`s two real fields) yet acts on
    # an existing `Aggregate` — completeness alone cannot tell these apart.
    #
    # THE HONEST TEST: with `references: nil` already narrowing to "no
    # explicit reference at all," a command creates the owner when it
    # supplies (via a `:set` mutation OR — `emit_command`'s own
    # `record_fields`, commands.rb — a same-named argument, copied straight
    # across with NO mutation required) at least one of the owner's own
    # REQUIRED (non-list, non-optional) fields. `Order.CreatePizza` supplies
    # `name`/`pizza` this way (both required) — that's real evidence of
    # building a genuinely new record. `Aggregate.Attribute`/`Aggregate.
    # Lifecycle` supply nothing of the kind: the first's every argument is
    # claimed by its own `append`, the second touches only `state_field`/
    # `state_start`, both `optional: true` — attaching a fact to a record
    # that must already exist is exactly what "nothing required is ever
    # newly supplied" looks like. A `:set`/bare-matched argument already
    # claimed by an APPEND (`ValueObject.Member`'s own `position`, feeding
    # the appended MEMBER's `position`, never `ValueObject`'s own
    # unrelated, declaration-order field of the same name) is excluded from
    # counting as such evidence — the exact bare-name coincidence this
    # whole fix exists to stop trusting blindly.
    def creates_owner?(aggregate, command, value_objects_by_name)
      return false unless command[:references].nil?

      owner_fields = aggregate[:attributes].map { |a| a[:name].to_s }.to_set
      owner_fields << aggregate[:lifecycle][:field].to_s if aggregate[:lifecycle]
      required_fields = aggregate[:attributes].reject { |a| a[:list] || a[:optional] }.map { |a| a[:name].to_s }.to_set

      # ARGUMENT NAMES ALREADY CLAIMED BY AN APPEND — collected first, so
      # an append's own element-field argument is never ALSO eligible to
      # bare-name-match an unrelated owner field that happens to share its
      # name (see this method's own header on `ValueObject.Member`).
      append_claimed = Set.new
      command[:mutations].each do |m|
        next unless m[:op].to_s == "append"

        Array(m[:fields]&.values).each do |v|
          source = append_field_source(v)
          append_claimed << source.to_s if source.is_a?(Symbol)
        end
      end

      known_writes = Set.new

      # A BARE-NAME MATCH — `record_fields` (commands.rb) copies a
      # creating command's argument straight into the same-named owner
      # field with no `:set` mutation required at all.
      command[:attributes].each do |attr|
        name = attr[:name].to_s
        known_writes << name if owner_fields.include?(name) && !append_claimed.include?(name)
      end

      # AN EXPLICIT `:set` MUTATION — covers the "renamed source" shape a
      # bare-name match alone can't (`sets :field, to: :other_arg`).
      command[:mutations].each do |m|
        next unless m[:op].to_s == "set"

        target = m[:target].to_s
        known_writes << target if owner_fields.include?(target)
      end

      required_fields.any? { |field| known_writes.include?(field) }
    end

    # `append`'s TARGET, resolved to whichever real thing it is — a plain
    # value object (`Order.toppings`, a `Vec<Topping>`) or an ENTITY
    # (`Account.ledger`, a `Vec<LedgerEntry>`) — so field-type lookups can
    # read `[:attributes]` the same way regardless of which. `nil` when
    # the attribute names neither (a codegen bug if reached; every real
    # append target already passed `unsupported_attribute_types` above).
    def append_element(aggregate, target_type, value_objects_by_name)
      # LOCAL FIRST — an aggregate's own nested entity is scoped to that
      # aggregate; `value_objects_by_name` is merged DOMAIN-WIDE (every
      # aggregate's own value objects, so a cross-aggregate reuse like
      # Translation's own TranslationName resolves at all). The two
      # namespaces aren't meant to collide, but the self-hosted grammar's
      # own Bluebook chapter proves they CAN: Command's domain-wide
      # value_object "Argument" (an ordinary command's own argument row)
      # and Syntax's own LOCAL entity "Argument" (S14, ADR 0026 — one row
      # of the syntax table itself, keyword/context/at/named/kind/...)
      # share a name purely by coincidence. Checking local first — same
      # "the aggregate's own declaration wins" precedent judge.rb's own
      # cross-aggregate value-object fallback already set — means Syntax's
      # OWN Argument entity resolves correctly; every other aggregate,
      # with no such collision, sees identical behavior either order.
      local = aggregate[:entities].find { |e| e[:name] == target_type }
      return local if local

      value_objects_by_name[target_type]
    end

    # An entity element's identity, auto-minted at append time exactly the
    # way `MutationApplier#entity_element` does it: sequential position
    # (`Array(current).size + 1`) wrapped into whichever single-field
    # value object the identity's own dotted path names —
    # `LedgerEntry.identified_by { sequence.value }`, the one real shape
    # this corpus needs. Returns `[attribute, its_value_object]`, or `nil`
    # when the shape doesn't match (a composite entity identity, or one
    # that isn't a bare-declared attribute) — command_skip_reason's half
    # of this pairing, same as every other bridgeable?/rhs pair here.
    def entity_identity_mint(entity, value_objects_by_name)
      id_path = entity[:identified_by]&.first
      return nil unless id_path

      head, *rest = id_path.split(".")
      return nil unless rest.size == 1

      attr = entity[:attributes].find { |a| a[:name].to_s == head }
      return nil unless attr

      vo = value_objects_by_name[attr[:type]]
      return nil unless vo && !vo[:closed_set] && vo[:attributes].size == 1 && vo[:attributes].first[:name].to_s == rest.first

      [attr, vo]
    end

    # Every `append` mutation's own field(s), checked against the element
    # they're building — the same "can we generate this" role
    # bridgeable_value_types?/literal_hash_bridgeable? already play for
    # `:set`, applied per-field instead of once. Two real problems this
    # catches that a blanket `.inspect`-string skip used to hide: a field
    # sourced from an argument whose type doesn't bridge to the field's
    # own declared type (`Credit`'s `PositiveMoney` `amount` into
    # `LedgerEntry`'s `Money` `amount` — DOES bridge, by field name; a
    # genuine mismatch would not), and — for an ENTITY target only — an
    # identity that can't be auto-minted and isn't supplied explicitly.
    def append_field_problems(command, aggregate, value_objects_by_name)
      command[:mutations].select { |m| m[:op].to_s == "append" }.flat_map do |m|
        target_attr = aggregate[:attributes].find { |a| a[:name].to_s == m[:target].to_s }
        element = target_attr && append_element(aggregate, target_attr[:type], value_objects_by_name)
        next ["#{m[:target]}: element type #{target_attr&.dig(:type).inspect} not resolvable"] unless element

        problems = m[:fields].filter_map do |field_name, source|
          field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
          next "#{m[:target]}.#{field_name}: not a declared field" unless field_attr

          # A SYMBOL names an argument, anything else IS the value — the one
          # distinction the wire spelling carries (Hecks::Literal), read
          # rather than sniffed off the first character.
          parsed = append_field_source(source)
          next literal_problem(m, field_name, parsed, field_attr, value_objects_by_name) unless parsed.is_a?(Symbol)

          arg_attr = command[:attributes].find { |a| a[:name].to_s == parsed.to_s }
          if arg_attr.nil?
            "#{m[:target]}.#{field_name}: sources undeclared argument #{parsed}"
          elsif !bridgeable_value_types?(arg_attr[:type], field_attr[:type], value_objects_by_name)
            "#{m[:target]}.#{field_name}: #{arg_attr[:type]} doesn't bridge to #{field_attr[:type]}"
          end
        end

        entity = aggregate[:entities].find { |e| e[:name] == target_attr[:type] }
        next problems unless entity

        present = m[:fields].keys.map(&:to_s)
        id_head = entity[:identified_by]&.first.to_s.split(".").first
        problems << "#{m[:target]}: #{entity[:name]}'s identity doesn't auto-mint" if !present.include?(id_head) && !entity_identity_mint(entity, value_objects_by_name)
        problems
      end
    end

    # `Marks.read` is the exact, already-proven inverse of the spelling
    # `appended_fields` writes — the OPPOSITE direction of the same round
    # trip the self-hosted grammar's own bootstrap uses it for. A Symbol
    # back means the field names a command ARGUMENT ; anything else IS the
    # literal value.
    def append_field_source(source) = Hecks::Bluebook::Assembly::Marks.read(source)

    def literal_problem(mutation, field_name, literal, field_attr, value_objects_by_name)
      return nil if literal_set_bridgeable?(literal, field_attr[:type], value_objects_by_name)

      "#{mutation[:target]}.#{field_name}: literal doesn't bridge to #{field_attr[:type]}"
    end

    # All transition rows this command names, collapsed into the one
    # `field`/`from_states` shape `TransitionCheck` wants — a command with
    # more than one `from:` (CloseAccount: from "open" OR "frozen") shares
    # one `to_state` across every matching row, per the "Lifecycles"
    # section above, so only `from_states` needs to be a list.
    def lifecycle_transition_for(command, aggregate)
      return nil unless aggregate[:lifecycle]

      rows = aggregate[:lifecycle][:transitions].select { |t| t[:command] == command[:name] }
      # `from:` WITHOUT a transition — `Admissibility#enforce_lifecycle_
      # guard`, read directly: a command that only guards on the current
      # state (a chess door's `from: "in_play"`) refuses with the same
      # transition_blocked wording a transition does and moves nothing.
      # `to_state: nil` is that "moves nothing"; every caller pushes the
      # state-setting line only when it is present.
      if rows.empty?
        froms = Array(command[:from]).compact.map(&:to_s)
        return nil if froms.empty?

        return { field: aggregate[:lifecycle][:field], to_state: nil, from_states: froms.uniq, unconstrained: false }
      end

      # `from: nil` — an UNCONSTRAINED transition, admitting from any
      # state (a creating command has no prior state to come from).
      # Ruby reads it as `!t.constrained? || Array(t.from).include?(...)`
      # (IR::Lifecycle#constrained? is `!@from.nil?`), so one such row
      # admits everything and the whole check is skipped. Left in,
      # `nil.inspect` renders as the literal Rust token `nil`, which is
      # not a Rust value: the generated crate does not compile.
      #
      # Carried BESIDE the compacted list rather than returning nil for
      # the row, because the caller reads this hash for TWO things — the
      # TransitionCheck guard AND the advance_lifecycle assignment of
      # to_state. Dropping the row would compile and silently stop
      # advancing the lifecycle: a wrong answer traded for a build error.
      froms = rows.map { |r| r[:from_state] }
      {
        field: aggregate[:lifecycle][:field],
        to_state: rows.first[:to_state],
        from_states: froms.compact.uniq,
        unconstrained: froms.any?(&:nil?)
      }
    end

    # Ruby's real `apply`, for `:set`, does `Value.for(aggregate,
    # mutation.target, value)` — it coerces whatever arrived into the
    # TARGET attribute's OWN declared type, not the source argument's.
    # `target_type` is that target type ("String" for the lifecycle field,
    # which is never VO-wrapped). The literal half is its own shape
    # (`literal_hash_rhs`, straight from the raw Hash — never `.inspect`'d,
    # see literal_set_bridgeable? above); the argument half is
    # `bridgeable_value_types?`/`value_rhs`'s shared job.
    def mutation_set_rhs(source, target_type, command, value_objects_by_name)
      if source[:kind] == "literal"
        return literal_rhs_for(source[:value], target_type, value_objects_by_name)
      end

      source_attr = command[:attributes].find { |a| a[:name].to_s == source[:name] }
      value_rhs("args.#{rust_ident_field(source[:name])}", source_attr[:type], target_type, value_objects_by_name)
    end

    # `:append` and `:set` — the two `sets` ops this slice generates.
    # `:set` has one real special case: the LIFECYCLE field is not one of
    # the aggregate's own `attributes` (see "Lifecycles" above), so it
    # can't be looked up there and isn't `Option`-wrapped on the record the
    # way every other field is — `Purchase`'s own `sets :status, to:
    # "sold"` is a real, redundant instance of this (redundant with the
    # transition's own advance, harmless, same pattern as `Account.Open`'s
    # redundant `sets` on an already-implicit creation attribute).
    # THE IDENTITY IS THE JOIN OF ITS PARTS (Naming::IDENTITY_JOIN is ":",
    # read directly) — one component per `identified_by` entry, each
    # resolved the same way `Runtime::Identity.from` resolves it: a
    # component whose HEAD names a declared command attribute walks into
    # that argument's own field (a dotted `rest` walks further into it —
    # `box_number.value`, a value-object-typed argument); a component
    # whose head is NOT a declared attribute (`owner_id` — "never a
    # declared attribute," per `language/bluebook/behavior.bluebook`'s own
    # comment) isn't in the command's own typed `XArgs` struct at all —
    # it's an addressing key allowed straight through `refuse_unknown_
    # arguments`'s allowlist the same way `id:` already is, so it never
    # became a struct field; the generated dispatch function instead takes
    # it as its own extra parameter, the same shape an acting command's
    # caller-supplied `id: &str` already has. `head:` (this branch only)
    # is that same fact one level RAWER than `expr`/`param` — the bare
    # JSON key `registry.rb`'s own router reads it off `args_json` under,
    # once it stops merely declaring the parameter and starts actually
    # supplying it.
    #
    # THE HEAD CHECK GOVERNS BOTH SHAPES, NOT JUST THE BARE ONE — this used
    # to branch on `rest.any?` FIRST, so any dotted path unconditionally
    # read `args.<head>.<rest>`, assuming the head was always one of this
    # command's OWN declared attributes. True for every ordinary domain's
    # creating command until the self-hosted meta-grammar's own
    # owner-mutating commands (`Aggregate.Identify` et al.) exercised the
    # one combination nothing else in the corpus had: a DOTTED identity
    # component (`name.value`, the meta-Aggregate's own name being a
    # single-field value object) whose head belongs to the OWNER being
    # mutated, not to the command's own args — `IdentifyArgs` has only
    # `path`, so `args.name` doesn't exist, and `cargo build` refused it.
    # The head-declared? check now gates BOTH shapes: undeclared means
    # external regardless of whether the path was dotted, because a value
    # supplied from outside args is already the resolved scalar the caller
    # read off the owner's own state — there is no `.value` left to walk.
    #
    # "DECLARED" MEANS a genuine `:set` mutation TARGETS this head — not
    # merely "some command attribute happens to share the head's name"
    # (the bare-name check this used to be). A dozen meta-domain "attach
    # one child to the owner" commands (`Aggregate.Attribute` et al.) each
    # declare an attribute coincidentally named the same as one of their
    # OWNER's identity components (both have a field called `name`) while
    # never setting the owner's own field at all — their one mutation
    # APPENDS that attribute into a list, sourced by that argument, which
    # is an entirely different thing from minting the owner's own id. See
    # `creates_owner?`'s own header (this file) for the full story; this
    # method is only ever consulted once that check has already said
    # `true`, but stays honest on its own terms rather than leaning on the
    # caller to have filtered first.
    def identity_components(aggregate, command)
      # THE SAME "DECLARED" TEST `creates_owner?` (this file, own header)
      # uses to count a field as supplied: a `:set` mutation targeting it,
      # OR a same-named command argument copied straight across by
      # `record_fields` (commands.rb) with no mutation at all — EXCLUDING
      # an argument already claimed by an append (`ValueObject.Member`'s
      # own `position`, coincidentally named, feeds the appended member's
      # `position`, never the owner's identity). A "creates" command whose
      # identity head is supplied this second way (`Governance::
      # RoleAssignment.Assign`'s own `actor_id`/`role_name`/`starts_at` —
      # no explicit `:set` at all, bare-name-matched like `Order.
      # CreatePizza`'s whole record) reads `args.<head>` exactly the same
      # as one supplied via an explicit `sets :<head>`.
      append_claimed = Set.new
      command[:mutations].each do |m|
        next unless m[:op].to_s == "append"

        Array(m[:fields]&.values).each do |v|
          source = append_field_source(v)
          append_claimed << source.to_s if source.is_a?(Symbol)
        end
      end
      declared_names = command[:attributes].map { |a| a[:name].to_s }.to_set - append_claimed

      aggregate[:identified_by].map do |path|
        head, *rest = path.split(".")
        set_target = command[:mutations].any? { |m| m[:op].to_s == "set" && m[:target].to_s == head }
        if set_target || declared_names.include?(head)
          if rest.any?
            { expr: "args.#{rust_ident_field(head)}.#{rest.map { |seg| rust_ident_field(seg) }.join('.')}.to_string()", param: nil }
          else
            { expr: "args.#{rust_ident_field(head)}.to_string()", param: nil }
          end
        else
          # `.to_string()` here too, matching the other two branches — a
          # single-component identity returns this expr UNWRAPPED
          # (build_identity_expr, below: `components.first[:expr]` when
          # there's only one), straight into a `Hydrate::Create { id: ...
          # }` field typed `String`. This param is `&str`; every other
          # branch already produces an owned `String`, so this was the one
          # combination (single identity component, and it's external) that
          # left a bare `&str` where `String` was expected — never hit
          # before the meta-grammar's own owner-mutating commands added a
          # case with exactly one identity part, entirely external.
          param = rust_ident_field(head)
          { expr: "#{param}.to_string()", param: "#{param}: &str", head: head }
        end
      end
    end

    def build_identity_expr(components)
      return components.first[:expr] if components.size == 1

      placeholders = components.map { "{}" }.join(":")
      "format!(#{placeholders.inspect}, #{components.map { |c| c[:expr] }.join(', ')})"
    end

    # One `append` field's value. An argument-sourced field runs through the
    # same `value_rhs` bridge `:set` does; a literal is built inline —
    # `append_field_source` (this file's own header) is the decode, the
    # SAME one `append_field_problems` above already used to confirm either
    # direction bridges before this could be reached. (Decoding through
    # `Marks.read`/`Literal.read` rather than a raw `"{"`-prefix string
    # check on `source` directly, because `source` here is the same
    # wire-spelled value `append_field_problems` already decoded that way —
    # `Marks.unmark` no longer exists post the Literal-pinning rework, one
    # reader now, `Literal.read`, reached through `Marks.read`.)
    #
    # `arg_attr[:optional]` — `mark_append_optional_fields!` (below) has
    # already run by the time this is reached, so `field_attr[:optional]`
    # is ALREADY true whenever `arg_attr[:optional]` is (that is the one
    # fact this whole file's own marking pass exists to guarantee) — the
    # `Option<T>`-aware bridge below is therefore always reaching for the
    # right target shape, never guessing. A caller-omittable argument's
    # own Rust field is `Option<T>` (commands.rb's own Args-struct rule),
    # so the ordinary `value_rhs` bridge — built to run against a bare
    # `T`, the same assumption `mutation_set_rhs`'s sibling `:set` path
    # gets to keep because ITS only optional+optional case is same-type,
    # never cross-type — cannot run directly against it; `optional_value_
    # rhs` runs that identical bridge against the value a `.map` closure
    # unwraps instead.
    def append_field_rhs(source, field_attr, command, value_objects_by_name)
      parsed = append_field_source(source)
      return literal_rhs_for(parsed, field_attr[:type], value_objects_by_name) unless parsed.is_a?(Symbol)

      arg_attr = command[:attributes].find { |a| a[:name].to_s == parsed.to_s }
      arg_expr = "args.#{rust_ident_field(arg_attr[:name])}"
      if arg_attr[:optional]
        # SAME REPRESENTATION on both sides (`SafeDepositBox::Visit.note`'s
        # own case: VisitNote -> VisitNote, no real coercion at all) needs
        # no per-element remap — `args.field` IS already the exact
        # `Option<TargetType>` the struct field wants, the identical
        # "just clone the Option itself" shortcut `mutation_set_rhs`'s
        # `:set` sibling already takes for its one optional+optional case.
        # Only a REAL cross-type coercion (`Field.default`'s own
        # `LiteralText -> String` unwrap) needs `optional_value_rhs`'s
        # own per-element `.map`.
        same_representation = arg_attr[:type] == field_attr[:type] ||
          (effective_scalar_type(arg_attr[:type]) && effective_scalar_type(arg_attr[:type]) == effective_scalar_type(field_attr[:type]))
        return "#{arg_expr}.clone()" if same_representation

        return optional_value_rhs(arg_expr, arg_attr[:type], field_attr[:type], value_objects_by_name)
      end

      rhs = value_rhs(arg_expr, arg_attr[:type], field_attr[:type], value_objects_by_name)
      # A field `mark_append_optional_fields!` made `Option<T>` for a
      # DIFFERENT command's own optional-sourced append (Field's own
      # `default`, fed both by `Attribute`'s optional argument AND —
      # nowhere in this corpus, but the shape is real — some sibling
      # command's non-optional one) still needs `Some(...)` here: THIS
      # source is required, but the STRUCT FIELD it lands in is optional
      # regardless of which command is filling it this time.
      field_attr[:optional] ? "Some(#{rhs})" : rhs
    end

    # THE OPTIONAL HALF of `value_rhs` — same bridge, run against `v`
    # (whatever a `.map` closure unwraps an `Option<T>` argument's clone
    # into) rather than against the raw `Option<T>` expression the
    # ordinary bridge assumes it never has to see. Produces an
    # `Option<TargetType>`, matching the field it feeds exactly — see
    # `append_field_rhs`'s own header for why the field is guaranteed to
    # already be that shape whenever this runs.
    def optional_value_rhs(source_expr, source_type, target_type, value_objects_by_name)
      "#{source_expr}.clone().map(|v| #{value_rhs('v', source_type, target_type, value_objects_by_name)})"
    end

    # THE STRUCT-LEVEL `Option<T>`-ness of an appended element's own
    # field, derived from USAGE — the same move `list_attr_creation_
    # optional?` already makes for a RECORD's own list field, generalised
    # to a per-FIELD append target (an entity's or a plain value object's,
    # `append_element`'s own either/or). Ruby's real `appended`
    # (mutation_applier.rb) resolves a Symbol source straight off `args`;
    # a caller-omitted `optional: true` argument reads there as a genuine
    # `nil`, and `Value.build` (coercion.rb) stores it WITHOUT complaint —
    # `language/bluebook/behavior.bluebook`'s own `Query.Option` says so
    # directly ("AN OPTION MAY HAVE NO VALUE... a rule about the
    # LANGUAGE, not about the one spec that noticed"). So one optional-
    # sourced `sets append` is reason enough to make the field's own
    # Rust type `Option<T>` for EVERY command that reaches it.
    #
    # Mutated onto the SAME attribute hash every other emitter here
    # already reads (`emit_value_object`/`emit_entity`'s own `attr
    # [:optional]` struct-field wrap, `optional_source_mismatches`'s own
    # skip check) — called once, before either of those run, so nothing
    # downstream ever has to learn a second, parallel notion of
    # "optional." Never turns a `true` back to `false` — a field the
    # domain author already marked optional by hand (`SafeDepositBox::
    # Visit.note`) needs no rederiving.
    def mark_append_optional_fields!(aggregate, value_objects_by_name)
      aggregate[:attributes].each do |target_attr|
        element = append_element(aggregate, target_attr[:type], value_objects_by_name)
        next unless element

        aggregate[:commands].each do |command|
          command[:mutations].each do |m|
            next unless m[:op].to_s == "append" && m[:target].to_s == target_attr[:name].to_s

            m[:fields].each do |field_name, source|
              # The same `append_field_source` decode `append_field_rhs`
              # itself uses — a Symbol back means an argument name (a
              # caller-omittable one is what this pass is looking for);
              # anything else IS a literal value, never optional.
              parsed = append_field_source(source)
              next unless parsed.is_a?(Symbol)

              source_attr = command[:attributes].find { |a| a[:name].to_s == parsed.to_s }
              next unless source_attr && source_attr[:optional]

              field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
              field_attr[:optional] = true if field_attr
            end
          end
        end
      end
    end

    # `optional:` — true for an aggregate RECORD (every non-list field is
    # `Option`-wrapped, emit_record's own reason) and false for an ENTITY
    # element (emit_entity's fields are plain, never `Option`-wrapped — an
    # entity command's own `element_of`/copy-on-write already guarantees
    # the element it hands `apply_mutations` exists, so there is nothing
    # for `Option` to represent here the way "field exists but is unset on
    # a freshly created aggregate" needs it to on a record).
    def emit_mutation_line(mutation, aggregate, command, value_objects_by_name, optional: true)
      target_field   = rust_ident_field(mutation[:target])
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s

      # The leading "        " restores the OLD code's own hardcoded
      # 8-space prefix — each `Exemplar.render` call below returns
      # flush-left text (a single-line shape's own dedent margin is
      # always its full indent, stripped to zero), and the CALLER
      # (commands.rb) joins these lines with "\n" expecting each one to
      # already carry its own indentation, the same as every other
      # single-line leaf in this generator.
      "        #{emit_mutation_line_body(mutation, aggregate, command, value_objects_by_name, target_field, lifecycle_field, optional)}"
    end

    def emit_mutation_line_body(mutation, aggregate, command, value_objects_by_name, target_field, lifecycle_field, optional)
      case mutation[:op].to_s
      when "append"
        target_attr = aggregate[:attributes].find { |a| a[:name].to_s == mutation[:target].to_s }
        vo_type = rust_ident(target_attr[:type])
        entity = aggregate[:entities].find { |e| e[:name] == target_attr[:type] }
        element = entity || value_objects_by_name[target_attr[:type]]

        fields_assignment = mutation[:fields].map do |field_name, source|
          field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
          "#{rust_ident_field(field_name)}: #{append_field_rhs(source, field_attr, command, value_objects_by_name)}"
        end

        # An ENTITY element carries two fields no `append: { ... }` binding
        # ever names, because Ruby never asks the caller to: its own
        # identity (auto-minted — entity_identity_mint, above, the same
        # `Array(current).size + 1` rule `entity_element` runs) and its own
        # lifecycle field (its declared `default:`, the same
        # `fields[entity.lifecycle.field] ||= entity.lifecycle.default`
        # entity_element runs). command_skip_reason already confirmed both
        # are mintable before this line could be reached.
        if entity
          present = mutation[:fields].keys.map(&:to_s)
          id_attr, id_vo = entity_identity_mint(entity, value_objects_by_name)
          if id_attr && !present.include?(id_attr[:name].to_s)
            mint = "#{rust_ident(id_attr[:type])} { #{rust_ident_field(id_vo[:attributes].first[:name])}: (record.#{target_field}.len() as i64) + 1 }"
            fields_assignment << "#{rust_ident_field(id_attr[:name])}: #{mint}"
            present << id_attr[:name].to_s
          end
          if entity[:lifecycle] && !present.include?(entity[:lifecycle][:field].to_s)
            fields_assignment << "#{rust_ident_field(entity[:lifecycle][:field])}: #{entity[:lifecycle][:default].inspect}.to_string()"
            present << entity[:lifecycle][:field].to_s
          end

          # A THIRD field no `append: { ... }` binding ever names, on top
          # of the two above: a LIST-typed attribute the entity declares
          # for some OTHER command to `append`/`remove` into later
          # (`ValueObject::Member#pairs`, bound only by its own `Pair`
          # command — S17, ADR 0026). Ruby's `entity_element`
          # (mutation_applier.rb) never sets this key at all when the
          # entity is minted — the fields Hash simply lacks it, and
          # everything downstream reads a missing list key as empty
          # (`Array(current)`, the same coercion `entity_identity_mint`'s
          # own `Array(current).size + 1` already relies on). A Rust
          # struct literal has no such absence to fall back on — every
          # field must be assigned at construction, so this ports that
          # same "unmentioned list starts empty" fact explicitly rather
          # than leaving the struct literal short a field and refusing to
          # compile. Found live: `ValueObject::Member`'s own `pairs`
          # (`list_of(Pair)`) reaching exactly this gap the first time
          # this generator was pointed at the self-hosted grammar's own
          # IR after S17 landed.
          entity[:attributes].each do |attr|
            next unless attr[:list]
            next if present.include?(attr[:name].to_s)

            fields_assignment << "#{rust_ident_field(attr[:name])}: Vec::new()"
            present << attr[:name].to_s
          end
        end

        Exemplar.render(
          "mutation_append",
          "tmpl_field" => target_field,
          "tmpl_fields_placeholder()" => "#{vo_type} { #{fields_assignment.join(', ')} }"
        )
      when "set"
        if mutation[:target].to_s == lifecycle_field
          rhs = mutation_set_rhs(mutation[:source], "String", command, value_objects_by_name)
          Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
        else
          target_attr = aggregate[:attributes].find { |a| a[:name].to_s == mutation[:target].to_s }
          rhs = mutation_set_rhs(mutation[:source], target_attr[:type], command, value_objects_by_name)
          source_attr = mutation[:source][:kind] == "argument" ? command[:attributes].find { |a| a[:name].to_s == mutation[:source][:name].to_s } : nil

          if target_attr[:list] && optional && list_attr_creation_optional?(aggregate, target_attr[:name], value_objects_by_name)
            # `CardPayment.Authorize`'s own redundant `sets :tags, to:
            # :tags` (the same "re-set an already-implicit creation
            # attribute" pattern `Purchase`'s own status set already is) —
            # `list_attr_creation_optional?` (this file's own header) is
            # the SAME check `emit_record`/`record_fields` used to
            # Option-wrap this record field in the first place, so the
            # redundant re-set assigns the SAME `Option<Vec<T>>` shape
            # straight across, no unwrapping.
            Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
          elsif target_attr[:list] && source_attr && source_attr[:optional]
            # A record's own list field is plain `Vec<T>` by DEFAULT
            # (`emit_record`'s rule, unless the branch above applies) — an
            # OPTIONAL source argument unwraps with the identical `[]`
            # fallback `record_fields`' own creation-time case uses —
            # cleanly resolvable, not the `optional_source_mismatches`
            # shape that has to be skipped.
            Exemplar.render("mutation_set_unwrap_or_default", "tmpl_field" => target_field, "tmpl_optional_rhs_placeholder()" => rhs)
          elsif target_attr[:list]
            Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
          else
            # `target_attr[:optional]` — a PER-FIELD `Option<T>` target
            # (0014/0015's struct-field change: `SafeDepositBox::Visit.note`,
            # written by `Visit.Annotate`'s `sets :note, to: :note`) —
            # not just `optional:`'s own whole-RECORD blanket wrap.
            #
            # `source_attr && source_attr[:optional]` — the SAME check
            # commands.rb's own record-creation path already makes
            # (see its "the optional arg's own Option<T> assigns
            # straight across" comment) and the sibling list-mutation
            # branch just above makes too: when the COMMAND's own
            # argument is already `Option<T>`, `rhs` already IS that
            # `Option<T>` — wrapping it again would be
            # `Option<Option<T>>`, not this field's real type,
            # regardless of whether `wrap` would otherwise be true for
            # blanket-record or per-field reasons.
            wrap = (optional || target_attr[:optional]) && !(source_attr && source_attr[:optional])
            if wrap
              Exemplar.render("mutation_set_wrapped", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
            else
              Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
            end
          end
        end
      when "increment", "decrement"
        target_attr, integer_field = arithmetic_target_field(mutation, aggregate, value_objects_by_name)
        vo_type = rust_ident(target_attr[:type])
        field_ident = rust_ident_field(integer_field)
        amount_expr = arithmetic_amount_expr(mutation[:source], command, value_objects_by_name, integer_field)
        # THE IR'S OWN sign FIELD, not re-derived from the op NAME — item
        # #5 of the whole-project table-unification survey.
        # `Bluebook::Mutation.sign_for` (command.rb) computes this once,
        # off `Vocabulary::MutationOp` (the same table Runtime::
        # CommandRules::Arithmetic::MUTATION_OPS is held equal to by
        # spec/vocabulary_conformance_spec.rb) — this used to restate the
        # fact independently via `mutation[:op].to_s == "increment"`.
        sign = mutation[:sign].to_s == "1" ? "+" : "-"
        current = optional ? "record.#{target_field}.clone().unwrap()" : "record.#{target_field}.clone()"
        updated = "#{vo_type} { #{field_ident}: current.#{field_ident} #{sign} (#{amount_expr}), ..current }"
        Exemplar.render(
          "mutation_arithmetic",
          "tmpl_field" => target_field,
          "tmpl_current_placeholder()" => current,
          "tmpl_updated_placeholder()" => (optional ? "Some(#{updated})" : updated)
        )
      end
    end
  end
end

require_relative "word_gate"
require_relative "aggregate_builder/sealing"
module Hecks
  module Bluebook
    module DSL
      # The `aggregate "Name" do ... end` receiver — the largest DSL builder
      # in the language, collecting everything an aggregate declares
      # (attributes, value objects, entities, commands, queries, policies,
      # invariants, preconditions, projected fields, its lifecycle and
      # identity) and assembling the final `Aggregate` IR in `#build`.
      # `entity`/`command`/`query` only queue a descriptor during
      # `instance_eval` (`#drain_pending!` builds them, in order, once the
      # whole block has run) so a later-declared piece can still be
      # referenced by an earlier line — see `#drain_pending!`'s own header.
      class AggregateBuilder
        GRAMMAR_CONTEXT = "Aggregate".freeze

        include AttributeCollector
        include IdentityDeclaration
        include RuleReference
        include WordGate
        include Sealing

        # @param name [String] the aggregate's name, as written after `aggregate`
        # @param chapter_named_givens [Hash{String => Hash{String => Bluebook::Given}}] the
        #   chapter-wide given pool, shared and written through by `given_impl`
        # @param chapter_pending_givens [Array<Hash>] unresolved chapter-wide bare given
        #   references, appended to when this aggregate's own reference cannot resolve yet
        # @param chapter_entity_named_givens [Hash{String => Hash{String => Bluebook::Given}}]
        #   the chapter-wide, entity-scoped given pool, threaded unchanged to every entity
        # @param chapter_entity_pending_givens [Array<Hash>] unresolved chapter-wide,
        #   entity-scoped bare given references, threaded unchanged to every entity
        def initialize(name, chapter_named_givens: {}, chapter_pending_givens: [],
                       chapter_entity_named_givens: {}, chapter_entity_pending_givens: [])
          @name          = name
          @value_objects = []
          @commands      = []
          @invariants    = []
          @named_givens  = {}
          @projected_fields = []
          @identity_paths = []
          @entities      = []
          @queries       = []
          @policies      = []
          @reference_targets = []
          # The root of the cross-entity given pool — see `#entity`'s own
          # comment. One hash for the whole aggregate, threaded unchanged
          # into every piece nested under it, however deep.
          @entity_named_givens = {}
          # **One level wider still** — the chapter's own pool, threaded in
          # from `BluebookBuilder#aggregate`, shared with every other
          # aggregate the same chapter builds. See `#given`'s own
          # comment for what this closes.
          @chapter_named_givens = chapter_named_givens
          # A chapter may be split across files — threaded in the same
          # way as `@chapter_named_givens`, one Array shared chapter-wide.
          # See `#pending_chapter_given`'s own comment for what queues
          # here and `BluebookBuilder#resolve_pending_chapter_givens!`
          # for where it drains.
          @chapter_pending_givens = chapter_pending_givens
          # One level wider still, past the chapter's own aggregate-level
          # pool — the chapter's own entity-scoped pool, threaded from
          # `BluebookBuilder#aggregate_impl` the same way
          # `@chapter_named_givens` is, and passed straight through
          # (unchanged) to every top-level piece this aggregate builds
          # (`#drain_pending!`). See `EntityBuilder#given_impl`'s own
          # comment for what this closes.
          @chapter_entity_named_givens   = chapter_entity_named_givens
          @chapter_entity_pending_givens = chapter_entity_pending_givens
          # **Deferred construction** — `entity`/`command`/`query` push a
          # pending descriptor here instead of building immediately; see
          # `#drain_pending!`'s own comment for why.
          @pending_entities = []
          @pending_commands = []
          @pending_queries  = []
        end

        # Sets the human-readable description shown for this aggregate.
        #
        # @param value [String] the description text
        # @return [String] the description as stored
        def description(value)
          # moved to the language: Description invariant, on Root.Declare

          @description = value
        end

        # Names where a concept adopted from a canonical source came from.
        #
        # Origin, not runtime identity — a concept adopted from a canonical
        # source (§28) names where it came from without that fact ever
        # touching `hecks_fqn`/dispatch. Captured raw, the same way
        # `attribute ..., default: { value: "small" }` captures a literal
        # Hash untouched — no re-parsing, no structure imposed beyond
        # "whatever the author wrote."
        #
        # Answers the `provenance` word (and, via the same table rows,
        # its siblings `projects`/`lifecycle`/`entity`/
        # `query`/`policy`/`command` below) through the table's `calls:`
        # column — item #13's full
        # metaprogrammed dispatch (slice 4c). All bootstrap-reachable
        # (used throughout the core/attached chapters), all in
        # `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`.
        #
        # @param from [Object] the canonical source, captured exactly as written
        # @return [Object] `from` as stored
        def provenance_impl(from:)
          @provenance = from
        end

        # Declares a reference from this aggregate's own head to another aggregate's identity.
        #
        # `optional:` — matching `CommandBuilder#reference_to`'s own
        # signature, which already had it, and forwarded here to
        # `attribute_impl()`/`relationship_attribute` (`optional: optional`, below). A real
        # need: an aggregate that can point at one
        # of several targets (Item's own `personal_list_id`/
        # `camping_list_id`, never both) needs each reference optional
        # on the aggregate's own persisted schema, not just as a
        # command's input — real corpus use:
        # `spec/fixtures/hop_chain.bluebook`'s own `Proposal` aggregate
        # declares `reference_to Engagement, optional: true` at the
        # aggregate head.
        #
        # Answers the `reference_to` word through the table's `calls:`
        # column — item #13's full metaprogrammed
        # dispatch (slice 4b). Bootstrap-reachable (every core/attached
        # grammar chapter uses reference_to to describe itself), so also
        # named in `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`.
        #
        # @param type [Module, Symbol, String] the referenced aggregate, written as a bare
        #   constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the reference may be absent
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `as` (or the derived name) is already declared
        def reference_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :reference_to,
                                 as || default_reference_name(target), optional: optional)
        end

        # Declares that this aggregate holds its own kept-fresh copy of a field reached through
        # a reference, so a rule can read it locally instead of reaching across the boundary.
        #
        # A rule may only read within its own aggregate boundary (S12,
        # ADR 0025 — "Consistency across aggregate boundaries"). Reaching through a
        # `reference_to` at rule-evaluation time (`References#
        # dereference`, a live query against another aggregate's own
        # repository) would be unbounded and inconsistent with the "a rule reads
        # only this record" model everywhere else — `projects` is what
        # replaces that: `projects :customer_status, from: :"customer.
        # status"` declares that this aggregate holds its own copy of
        # `Customer`'s own `:status`, kept fresh by a rebuild sweep
        # (`Runtime::ProjectionRebuild`) rather than read live. A rule
        # then reads `customer_status` the same way it reads any other
        # local field — no dot, no reference walk.
        #
        # `from:` names the local reference, not the target aggregate —
        # `customer`, the attribute this aggregate's own `reference_to
        # Customer` already minted, not `Customer` the type — so two
        # references to the same aggregate (aliased differently) can
        # each carry their own projection without ambiguity. The target
        # field's own existence cannot be checked here: the target
        # aggregate does not exist yet while this one is still being
        # declared (the same reason a query's own hop tail is checked
        # by `BluebookBuilder#validate_query_hops!`, once every
        # aggregate in the chapter is real, not by `AggregateBuilder`
        # itself) — `validate_projected_fields!` is where that half
        # happens.
        #
        # @param name [Symbol, String] the local field's name this aggregate projects the
        #   remote value into
        # @param from [Symbol, String] the local reference and remote field, dotted, such as
        #   `:"customer.status"`
        # @return [Array<Bluebook::ProjectedField>] every projected field declared so far, this
        #   one last
        # @raise [Bluebook::DSL::Malformed] if `from` is not `reference.field` shaped
        def projects_impl(name, from:)
          reference, _, remote_field = from.to_s.rpartition(".")

          if reference.empty? || remote_field.empty?
            raise Malformed,
                  "#{@name}.projects :#{name} names #{from.inspect}, which is not " \
                  "reference.field — say which reference and which field on it, e.g. " \
                  "from: :\"customer.status\""
          end

          @projected_fields << ProjectedField.new(name: name.to_sym, reference: reference.to_sym,
                                                  remote_field: remote_field.to_sym)
        end

        # `has_many`/`has_one`/`belongs_to` were legacy (ADR 0025,
        # "References") — sugar over `reference_to` that collapsed to an
        # anonymous reference and, for `has_many`, lied (singularised its
        # target and minted one scalar, so `film.backers` read `nil` and
        # never `[]`). Wave 6 (identity-and-relationships arc) un-deprecates
        # all three for real: a relationship word now retains the author's
        # domain concept in IR — still stored as one or more target
        # identities, but no longer collapsed to a bare `reference_to`
        # during assembly. `MetaValidator.shadow_parsing?` still routes to
        # `legacy_has_many`/`legacy_has_one` so frozen era text written
        # under the old (lying/collapsing) meaning still parses the way it
        # did when it was written — real, if rare corpus: "Combined corpus
        # uses: one."
        #
        # Declares a list-typed relationship to another aggregate, referenced by its plural name.
        #
        # Answers the `has_many` word (and, via the same table rows, its
        # siblings `has_one`/`belongs_to` below) through the table's
        # `calls:` column — item #13's full metaprogrammed dispatch
        # (slice 4). Each Keyword row's own `calls:` names the matching
        # `_impl`, so all three are carried in
        # `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK` like every other
        # `calls:`-routed word, but never actually exercised during real
        # bootstrap (no core/attached chapter uses one of these to
        # describe itself), unlike `attribute`/`role`.
        #
        # @param type [Module, Symbol, String] the related aggregate's plural name, a bare
        #   constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param legacy_options [Hash] must be empty outside shadow-parsing; under
        #   shadow-parsing, `:optional` is read for the legacy single-reference form
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] outside shadow-parsing, if `legacy_options` is
        #   non-empty; may also raise from `relationship_attribute` if the derived name is
        #   already declared
        def has_many_impl(type, as: nil, **legacy_options)
          return legacy_has_many(type, as: as, optional: legacy_options.fetch(:optional, false)) if MetaValidator.shadow_parsing?

          unless legacy_options.empty?
            raise Malformed,
                  "#{@name}.has_many takes no #{legacy_options.keys.first}: — an empty list already means none"
          end

          plural = Naming.demodulise(type)
          target = Naming.singularize(plural)
          @reference_targets << target
          relationship_attribute(target, :has_many, as || Naming.snake(plural).to_sym,
                                 list: true)
        end

        # Declares a single-valued relationship this aggregate holds toward another.
        #
        # @param type [Module, Symbol, String] the related aggregate, a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the relationship may be absent
        # @return [void]
        def has_one_impl(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :has_one, as || Naming.snake(target).to_sym,
                                 optional: optional)
        end

        # Declares a single-valued relationship toward the aggregate that owns this one.
        #
        # @param type [Module, Symbol, String] the owning aggregate, a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the relationship may be absent
        # @return [void]
        def belongs_to_impl(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :belongs_to, as || Naming.snake(target).to_sym,
                                 optional: optional)
        end

        # Declares this aggregate's own state machine.
        #
        # @param field [Symbol, String] the attribute the state machine lives on
        # @param default [String, Symbol] the state a new record starts in
        # @yield the lifecycle body of `transition` rows, evaluated against a `LifecycleBuilder`
        # @return [Bluebook::Lifecycle] the built state machine
        # @raise [Bluebook::DSL::Malformed] if two transitions for one command overlap
        def lifecycle_impl(field, default:, &)
          @lifecycle = LifecycleBuilder.build(field, default: default, &)
        end

        # Queues a piece nested in this aggregate, built later once every sibling has been seen.
        #
        # A piece is declared in this aggregate — its owner is stamped by
        # `Aggregate#initialize`, once the aggregate exists. Its own
        # commands were given the piece as their owner when it was declared,
        # so the chain closes as chapter -> aggregate -> entity -> command.
        # Not built here — see `#drain_pending!`'s own comment for why
        # this only queues a descriptor.
        #
        # A precondition shared across sibling pieces, declared once — one
        # level wider than round 4's own `EntityBuilder#given` (shared
        # across one piece's own commands): `@entity_named_givens` is the
        # same hash threaded into every piece this aggregate builds, so a
        # piece's own entity-level `given(desc) { block }` write-throughs
        # into it, and any other piece's own command can reference it back
        # bare, the identical description/canonical, evaluated in its own
        # `parent`-relative context. Real, live corpus this closes:
        # `SafeDepositBox`'s `Visit`/`KeyIssuance` — two different pieces
        # under one head, each independently typing `given("customer is
        # active") { parent.customer.status == "active" }` byte for byte,
        # which neither the aggregate's own "customer is active" (a
        # different canonical — bare `customer.status`, not
        # `parent.customer.status`, wrong scope for a piece's own command
        # to evaluate) nor round 4's single-piece `given` could reach.
        # @param name [String] the nested piece's name
        # @yield the piece body, evaluated against an `EntityBuilder` once drained
        # @return [Array<Array>] every pending piece queued so far, this one last
        def entity_impl(name, &block)
          @pending_entities << [name, block]
        end

        # Queues a query declared on this aggregate, built later once every sibling has been seen.
        #
        # @param name [String] the query's name
        # @yield the query body, evaluated against a `QueryBuilder` once drained
        # @return [Array<Array>] every pending query queued so far, this one last
        def query_impl(name, &block)
          @pending_queries << [name, block]
        end

        # Declares a policy scoped to this aggregate, stamping it with the aggregate's own name.
        #
        # @param name [String] the policy's name
        # @yield the policy body, evaluated against a `PolicyBuilder`
        # @return [Array<Bluebook::Policy>] every policy declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if the body fails any check the policy builder raises
        def policy_impl(name, &)
          reaction = PolicyBuilder.build(name, &)
          reaction.aggregate = @name
          @policies << reaction
        end

        # Declares a value object on this aggregate, either as a block of `attribute` lines or
        # (the `type` shorthand) as a single `:value` attribute.
        #
        # `builder.closed_sets` too, not only `builder.build` — a real
        # gap this exact fix closes: a
        # value_object's own inline `attribute :x, one_of(...)` (legal
        # since S3, ADR 0025 removed the wrong-arity collision that would
        # otherwise crash it) synthesises its own
        # anonymous value object via the same `AttributeCollector#closed_
        # sets` mechanism an aggregate's own attributes already use — and
        # nothing installed it anywhere. `Box.attributes` said `size:
        # "Size"` while no "Size" value object existed in the whole
        # domain: a dangling type name, not a working closed set. Flattened
        # into this aggregate's own `@value_objects`, the identical move
        # `@value_objects + closed_sets` already makes for the aggregate's
        # own direct attributes (see this file's other 5 call sites).
        # `type` — the bare shorthand (single-attribute value objects):
        # `value_object :Price, Integer` declares a value object with
        # exactly one attribute, named `value`, of that type — pure sugar
        # for `value_object("Price") { attribute :value, Integer }`,
        # routed through the same `attribute_impl` the block form's own
        # `attribute` line reaches (so the quoted-text-type refusal,
        # `one_of(...)`/`list_of(...)` synthesis, everything an attribute
        # line already does, applies unchanged rather than being
        # re-derived here). The name `value` is not arbitrary: a
        # single-attribute value object is a name for a scalar, not a
        # genuine group ([[feedback_name_the_scalar_field]], `Behaviour::
        # ValueObject#sole_attribute`), and `value` is what the language
        # guarantees every sole field answers to at runtime regardless of
        # its declared name (`Runtime::Value#method_missing`'s alias) —
        # so the shorthand simply declares it under the canonical name
        # directly. Type and block together are refused: the block exists
        # to say what the fields are, and the type just said it — two
        # answers to one question is an authoring error, never a merge.
        # Neither type nor block keeps its historical behavior untouched
        # (an empty attribute list — judged, or not, by the language
        # downstream, the same as before this parameter existed).
        #
        # @param name [String] the value object's name
        # @param type [Module, nil] the bare shorthand's single attribute type; mutually
        #   exclusive with `block`
        # @yield the value object body of `attribute`/`invariant`/`one_of` lines; mutually
        #   exclusive with `type`
        # @return [Array<Bluebook::ValueObject>] this aggregate's own value objects, including
        #   this one and any closed sets its attributes synthesised
        # @raise [Bluebook::DSL::Malformed] if both `type` and a block are given, or the body
        #   fails any check the value object language or its builder raises
        def value_object(name, type = nil, &block)
          if type && block
            raise Malformed,
                  "#{name} declares both a type (#{type.inspect}) and a block — " \
                  "value_object #{name.inspect}, Type is sugar for a block declaring " \
                  "exactly one attribute named :value; write one form or the other, never both"
          end

          builder = ValueObjectBuilder.new(name, owner_value_objects: @value_objects + closed_sets)
          builder.attribute_impl(:value, type) if type
          builder.instance_eval(&block) if block
          @value_objects << builder.build
          @value_objects.concat(builder.closed_sets)
        end

        # Queues a command declared on this aggregate, built later once every sibling has been
        # seen.
        #
        # `from:` — lifecycle state becomes a command guard (S10, ADR
        # 0025) — `command "Debit", from: "open"` replaces `given
        # ("account is open") { status == "open" }`, written 35 times
        # in two wordings across the corpus. Checked against this
        # aggregate's own lifecycle field (`Admissibility#enforce_
        # lifecycle_guard`) — never a target state, never a transition:
        # the lifecycle already declares which states exist, so naming
        # the legal ones is checkable against it, where a free-text
        # given could drift out of sync with the state machine and did.
        #
        # @param name [String] the command's name
        # @param from [String, Symbol, Array<String, Symbol>, nil] the lifecycle state(s) this
        #   command guards from; nil admits from any state
        # @yield the command body, evaluated against a `CommandBuilder` once drained
        # @return [Array<Array>] every pending command queued so far, this one last
        def command_impl(name, from: nil, &block)
          # The verb is declared on this aggregate — the owner `acts_on` answers
          # with — stamped by `Aggregate#initialize` once the aggregate
          # exists. An entity's commands take the entity as their owner instead,
          # at the entity's own declaration. Not built here — see
          # `#drain_pending!`'s own comment for why this only queues a
          # descriptor.
          @pending_commands << [name, from, block]
        end

        # Declares a rule this aggregate's own commands must satisfy, or references one a
        # sibling aggregate in the chapter already declared.
        #
        # A precondition shared across commands, declared once (S10, ADR
        # 0025) — an aggregate-level `given`, block required, stored by
        # its own description rather than appended anywhere: a command
        # names it back (`given("customer is active")`, no block of its
        # own) rather than re-typing the predicate, so there is one
        # description and therefore one refusal message no matter which
        # command a caller hits. Declare before the commands that
        # reference it — resolution happens at the referencing command's
        # own build time (`CommandBuilder#given`), against whatever this
        # aggregate has declared so far, the one ordering constraint this
        # word carries that `identified_by`/`attribute` do not.
        # Bare — no block — references a sibling aggregate's own
        # already-declared precondition, one level wider than the
        # existing bare-command-references-its-own-aggregate shape
        # (`CommandBuilder#reference_named_given`): `SafeDepositBox`/
        # `OnboardingCase` both name back `Account`'s own "customer is
        # active" rather than retyping `customer.status == "active"` a
        # third and fourth time. Resolved against `@chapter_named_givens`
        # — see `BluebookBuilder#aggregate`'s own comment for how that
        # pool is threaded, and `docs/implemented/resolution-rules/chapter-given.md`
        # for the full algorithm and its known limitations (a bare
        # reference trusts its own author to have verified the same
        # canonical predicate applies — this mechanism does not, and
        # cannot, check that itself; see that doc for which real corpus
        # cases do and do not qualify).
        #
        # `declared_by:` disambiguates the same description meaning two
        # genuinely different predicates chapter-wide — real, live:
        # `Account`'s own "customer is active" reads bare
        # `customer.status` (a direct `reference_to Customer`); `ATMCard`'s
        # own (shared onward with `CardPayment`/`ExternalTransfer`/
        # `ScheduledPayment`/`Statement`) reads `account.customer.status`
        # (reached through `Account`) — the identical business fact, a
        # genuinely different runtime path, correctly kept as the same
        # domain wording rather than invented a second spelling for "the
        # same idea, one more hop away" (S10, ADR 0025's own "one idea,
        # one spelling"). Omit it when the description is unambiguous
        # chapter-wide (the common case, and the only case this took
        # before this parameter existed) — required only once a second,
        # textually-different canonical registers under the same
        # description; see `reference_named_chapter_given`'s own
        # ambiguity error for how that surfaces.
        # Answers the `given` word through the table's `calls:` column —
        # item #13's full metaprogrammed dispatch
        # (slice 4b), same reasoning as `reference_to_impl` above:
        # bootstrap-reachable, in `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`.
        #
        # @param description [String] the rule's description; also the name a sibling aggregate
        #   references it by when no block is given
        # @param declared_by [Module, Symbol, String, nil] disambiguates which aggregate's own
        #   rule to reference, a bare constant, when more than one shares `description`; only
        #   meaningful with no block
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if given a block whose source cannot be extracted;
        #   given no block, the description is immediately ambiguous between more than one
        #   already-loaded aggregate with no `declared_by` to disambiguate; an unresolved
        #   reference defers instead, and may still raise once the whole chapter has loaded, if
        #   it then resolves to none or more than one candidate
        def given_impl(description, declared_by: nil, &predicate)
          return reference_named_chapter_given(description, declared_by: declared_by) unless predicate

          named = build_rule(Given, description, predicate, owner_name: @name, word: "given",
                              extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
          @named_givens[description] = named
          # Write-through, first-declared-wins per owner — keyed by
          # [description, this aggregate's own name], not description
          # alone: two different aggregates independently declaring the
          # same description are two distinct candidates a later bare
          # reference chooses between (via `declared_by:` once there is
          # more than one), never silently merged into one slot the way
          # a bare description-only key would.
          @chapter_named_givens[description] ||= {}
          @chapter_named_givens[description][@name] ||= named
        end

        private

        # Primitive 2 (RuleReference#resolve_owner_keyed) — see that
        # method's own comment for the pool shape; the three branches
        # below (exact owner / unambiguous single candidate / ambiguous)
        # are this construct's own refusal wording, not shared, since
        # `declared_by:` only exists here so far. Unresolved (no
        # candidate yet, or `declared_by:` naming an aggregate that
        # hasn't declared it yet) is no longer a fourth branch that
        # raises here — see `#pending_chapter_given`, below, for why:
        # a chapter split across files can genuinely reference a
        # precondition a later file declares, and "not found among
        # what's loaded so far" cannot tell that apart from "genuinely
        # never declared" until every file has.
        def reference_named_chapter_given(description, declared_by:)
          verify_resolves_via!("given", "Aggregate", "owner_keyed")
          candidates = resolve_owner_keyed(@chapter_named_givens, description)

          named =
            if declared_by
              owner = Naming.demodulise(declared_by)
              candidates[owner] || pending_chapter_given(description, declared_by: owner)
            elsif candidates.size == 1
              candidates.values.first
            elsif candidates.empty?
              pending_chapter_given(description, declared_by: nil)
            else
              raise(Malformed,
                    "#{@name}'s given #{description.inspect} is ambiguous in this chapter — " \
                    "#{candidates.keys.join(', ')} each declare a DIFFERENT predicate under " \
                    "this same description; name which one with declared_by: (e.g. " \
                    "given(#{description.inspect}, declared_by: #{candidates.keys.first}))")
            end

          @named_givens[description] = named
        end

        # A chapter may be split across files — the same reason a query
        # hop's own cross-file target, a correlation key's own emitting
        # command, and an event's own declared shape are all resolved
        # once the whole chapter is assembled rather than refused the
        # moment one file's own bare reference outruns what's loaded so
        # far (`BluebookBuilder.validate_assembled!`'s own comment).
        #
        # Unlike those, though, a chapter-given's resolved value is not
        # a pass/fail check on an already-built IR — it is part of the
        # referencing aggregate's own IR (`preconditions:` below), built
        # and handed off the moment this aggregate's own file finishes
        # loading, long before a later file might declare the real
        # thing. So this hands back a placeholder `Given` — embedded
        # exactly where the resolved one would be, by Ruby object
        # reference, in this aggregate's own `preconditions` and in any
        # command in this same aggregate that separately bare-references
        # the same description (`CommandBuilder#given`'s own hash-chain
        # read of this aggregate's `@named_givens`, the identical key) —
        # and queues the request in `@chapter_pending_givens`.
        # `BluebookBuilder#resolve_pending_chapter_givens!` mutates this
        # exact object in place, once every file has loaded, so every
        # existing reference to it (there is only ever the one object,
        # never a copy) sees the resolved fields simultaneously. Safe
        # because every real reader of a `Given` — refusal wording at
        # dispatch, `Aggregate`'s own lazy `-> { preconditions.map { ... } }`
        # IR accessor, docs — runs strictly after boot completes, never
        # mid-load; `judge_deferred!` resolves every pending chapter-given
        # before anything else touches this chapter's assembled IR.
        def pending_chapter_given(description, declared_by:)
          placeholder = Given.new(description: description, canonical: nil, predicate: nil)
          @chapter_pending_givens << { aggregate: @name, description: description,
                                        declared_by: declared_by, placeholder: placeholder }
          placeholder
        end

        public

        # Declares a rule the whole aggregate must satisfy, checked after every command, before
        # save.
        #
        # The aggregate boundary is what an invariant defines (S10, ADR
        # 0025 — "Rules") — the same check a value object's already gets
        # (`ValueObjectBuilder#invariant`, whose own shape this mirrors
        # exactly). Without an aggregate-level rule, "the balance
        # never goes negative" was three different `given`/`ensures`
        # texts across banking's six balance-moving commands, and the
        # four that only increase it said nothing at all — completeness
        # depended on someone noticing which commands could decrease it.
        #
        # Answers the `invariant` word through the table's `calls:`
        # column — item #13's full metaprogrammed
        # dispatch (slice 4b), same reasoning as `given_impl` above.
        #
        # @param description [String] the rule's description
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the block's source could not be extracted
        def invariant_impl(description, &predicate)
          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
        end

        # Assembles every declared attribute, construct and rule into an `Aggregate`, after
        # draining pending commands/queries/entities and running every `seal_*` check.
        #
        # @return [Bluebook::Aggregate] the built aggregate
        # @raise [Bluebook::DSL::Malformed] if identity resolution or any `seal_*` check fails —
        #   a mutation or query naming an undeclared field, an inconsistent default, a lifecycle
        #   guard with no lifecycle, a lifecycle-field mutation outside a transition, a projected
        #   field naming an undeclared reference, or a correction targeting an unreferenced field
        def build
          drain_pending!
          resolve_pending_identity!
          seal_mutation_targets
          seal_query_targets
          seal_defaults
          seal_lifecycle_guards
          seal_projected_fields
          seal_correction_targets

          ir = Aggregate.new(
            name:              @name,
            description:       @description,
            attributes:        attributes,
            value_objects:     @value_objects + closed_sets,
            commands:          @commands,
            invariants:        @invariants,
            preconditions:     @named_givens.values,
            projected_fields:  @projected_fields,
            identified_by:     @identity_paths,
            lifecycle:         @lifecycle,
            entities:          @entities,
            queries:           @queries,
            policies:          @policies,
            reference_targets: @reference_targets + entity_reference_targets,
            provenance:        @provenance
          )

          # After the IR exists, on purpose : a reference is declared in the
          # aggregate, and the aggregate the IR graph knows is `ir`, not the
          # builder.
          stamp_references(ir)
          ir
        end

        # Evaluates an `aggregate` block against a fresh builder and returns the built aggregate.
        #
        # @param name [String] the aggregate's name
        # @param chapter_named_givens [Hash{String => Hash{String => Bluebook::Given}}] the
        #   chapter-wide given pool
        # @param chapter_pending_givens [Array<Hash>] unresolved chapter-wide bare given
        #   references
        # @param chapter_entity_named_givens [Hash{String => Hash{String => Bluebook::Given}}]
        #   the chapter-wide, entity-scoped given pool
        # @param chapter_entity_pending_givens [Array<Hash>] unresolved chapter-wide,
        #   entity-scoped bare given references
        # @yield the aggregate body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Aggregate] the built aggregate
        # @raise [Bluebook::DSL::Malformed] if the body fails any check `#build` raises
        def self.build(name, chapter_named_givens: {}, chapter_pending_givens: [],
                       chapter_entity_named_givens: {}, chapter_entity_pending_givens: [], &block)
          builder = new(name, chapter_named_givens: chapter_named_givens, chapter_pending_givens: chapter_pending_givens,
                              chapter_entity_named_givens: chapter_entity_named_givens,
                              chapter_entity_pending_givens: chapter_entity_pending_givens)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # Deferred construction — `entity`/`command`/`query` queue a descriptor rather than
        # building immediately, inline, the moment their own DSL line runs during
        # `instance_eval`. Building immediately would mean a command's own resolution (`sets
        # :field` importing the owner's own attribute, `given("desc")`
        # referencing an aggregate-level precondition, a query's own
        # positional-param resolution) only ever saw whatever `@entities`/
        # `attributes`/`@named_givens`/`@value_objects` held as of that
        # exact textual line — never what the aggregate's block would go
        # on to declare after it. Three real, confirmed cases in the
        # self-hosted meta-domain violate the "declare before you
        # reference" convention every other resolution rule relies on
        # (`command "Handler"` before `entity "Handler"`, same for
        # Member/Dispatch — see docs/resolution-rules/
        # implicit-append-fields.md's own "Known limitations").
        #
        # This is the same move `BluebookBuilder` already makes one level
        # up, at the chapter level — build every aggregate first, then run
        # cross-referential validation (`validate_query_hops!`,
        # `validate_projected_fields!`, `validate_no_bidirectional_
        # references!`) once `@aggregates` is fully populated — extended
        # one level down: `entity`/`command`/`query` now only queue a
        # descriptor (`@pending_entities`/`@pending_commands`/
        # `@pending_queries`, each preserving its own declared order),
        # and `#build` drains them here, in this exact order, before any
        # of the existing `seal_*` validations (which already assume
        # `@commands`/`@entities`/`@queries` are the real, final, built
        # objects) — entities first and fully, since a command's own
        # `sets :list, append: {...}` needs a list's element entity
        # already built (`.attributes` populated) to resolve against, not
        # just named.
        #
        # `attribute`/`value_object`/`identified_by`/`given` (block form)
        # are not deferred — they still build eagerly during
        # `instance_eval`, unchanged. Nothing reads `@entities`/
        # `@commands`/`@queries` from anywhere other than `#build` and its
        # own private helpers (checked directly), so nothing else in this
        # file needed to change for this to be safe.
        def drain_pending!
          @entities = @pending_entities.map do |name, block|
            EntityBuilder.build(name, owner_value_objects:             @value_objects + closed_sets,
                                      owner_named_givens:              @entity_named_givens,
                                      identity_name_prefix:            "#{Naming.demodulise(@name)}#{Naming.demodulise(name)}",
                                      identity_value_object_installer: ->(value_object) { @value_objects << value_object },
                                      aggregate_name:                  @name,
                                      chapter_entity_named_givens:     @chapter_entity_named_givens,
                                      chapter_entity_pending_givens:   @chapter_entity_pending_givens,
                                &block)
          end

          @commands = @pending_commands.map do |name, from, block|
            CommandBuilder.build(name, owner: @name, from: from, named_givens: @named_givens,
                                        owner_attributes: attributes,
                                        owner_constructs: @value_objects + closed_sets + @entities, &block)
          end

          @queries = @pending_queries.map do |name, block|
            QueryBuilder.build(name, owner_attributes: attributes, &block)
          end
        end

        # `identified_by`'s own resolution pool (AttributeCollector#resolve_
        # pending_identity!'s hook, S9) — an aggregate resolves a bare
        # field's own value-object type against everything it declares
        # itself, own inline closed sets included.
        def identity_pool = @value_objects + closed_sets

        def identity_value_object_name = "#{Naming.demodulise(@name)}Identity"

        def install_identity_value_object!(value_object)
          @value_objects << value_object
        end

        # Legacy — see `has_many`/`has_one`/`belongs_to`'s own comment;
        # byte-identical to what those three did before this slice.
        def legacy_has_many(type, as:, optional: false)
          plural = Naming.demodulise(type)
          reference_to_impl(Naming.singularize(plural), as: as || Naming.snake(plural).to_sym, optional: optional)
        end

        def legacy_has_one(type, as:, optional: false)
          reference_to_impl(type, as: as || Naming.snake(Naming.demodulise(type)).to_sym, optional: optional)
        end
      end
    end
  end
end

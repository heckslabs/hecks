require_relative "value"
require_relative "identity"
require_relative "../ports/persistence/codec_boundary"

module Hecks
  module Runtime
    # One aggregate (or entity) record's runtime state: the declared
    # attributes hydrated with defaults, plus the identity (`id`) and,
    # for a CAS-capable adapter, the optimistic-concurrency `version`
    # stamped on it. `[]`/`[]=`/method_missing give state-field access;
    # `to_h` is the wire/storage shape with `id` merged in last so a
    # same-named declared attribute can never clobber it.
    class Instance
      attr_reader :aggregate, :id
      attr_accessor :state
      # **Out-of-band adapter bookkeeping, not domain state** — the optimistic-
      # concurrency version a CAS-capable adapter (Postgres today) stamps
      # on a record it reads/writes, so a later `save` can assert "commit
      # only if nobody has written since". Deliberately absent from
      # `to_h`/`[]`/`[]=`/`method_missing` : a domain author never declares
      # this, a `given`/`ensures`/`invariant` can never read it, and no
      # adapter that doesn't understand it (Memory, Heki) ever sets it —
      # `nil` there just means "no CAS attempted", which is exactly what a
      # plain `save` already does. See docs/decisions/ (concurrency-control
      # ADR) for the full mechanism.
      attr_accessor :version

      # `args:` — the original command payload, offered only by a fresh
      # creation (`CommandInterpreter#hydrate_legacy_creation`/
      # `#hydrate_complete_state`/`#hydrate_prior_or_initial`, each already
      # holding it when they mint a brand-new record). See
      # `materialize_identity!` for why a composite identity needs it.
      #
      # `hydrate:` — on by default, and every existing caller keeps getting
      # exactly what it always got: `state` re-walked through
      # `hydrate_with_defaults` (declared defaults filled, every attribute
      # re-coerced through `Value.for_attribute`, an entity list's every
      # element rebuilt and re-validated). `false` is for exactly one
      # caller (`Adapters::Memory#build_instance`, judge-bootstrapping
      # only — see its own header) that already knows `state` needs none
      # of that: it is a shallow dup of an already-hydrated, already-
      # validated live `Instance`'s own state, not a raw value pulled off
      # a wire. Skipping the re-walk is what turns a `list_of` entity's Nth
      # save from O(N) (re-hydrating every element saved so far, for every
      # save) into O(1) — the quadratic cost `Adapters::Memory`'s own
      # header traces start to finish. `CodecBoundary.check_state!` still
      # runs either way ; only the re-hydration is skipped.
      #
      # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct this
      #   record's state is declared by
      # @param id [String, nil] this record's identity; nil for a record whose identity
      #   is not yet resolvable (e.g. an entity element hydrated before its own view exists)
      # @param state [Hash{Symbol => Object}, nil] the record's stored (or partial)
      #   attribute values; nil for a brand-new record, hydrated entirely from declared
      #   defaults
      # @param args [Hash{Symbol => Object}, nil] the original command payload, offered
      #   only by a fresh creation; materializes a composite identity's own head
      #   attributes
      # @param hydrate [Boolean] whether `state` is re-walked through
      #   `hydrate_with_defaults`; false only for a caller that already knows `state` is
      #   already hydrated and validated
      def initialize(aggregate:, id:, state: nil, args: nil, hydrate: true)
        @aggregate = aggregate
        @id        = id
        # Inside a persistence adapter call this refuses undecoded stored
        # state (Ports::Persistence::CodecBoundary); everywhere else, no-op.
        Ports::Persistence::CodecBoundary.check_state!(aggregate, state) if state
        @state = if !hydrate
                   state || self.class.defaults(aggregate)
                 elsif state
                   self.class.hydrate_with_defaults(aggregate, state)
                 else
                   self.class.defaults(aggregate)
                 end
        @version = nil
        materialize_identity!(args)
      end

      # Loading existing state runs the same default-fill a fresh instance
      # gets: an attribute the record predates — a newly-required field
      # with a declared default:, a list added since the record was
      # written — arrives filled instead of nil. Only declared defaults
      # fill in; an attribute with no default stays absent, exactly as
      # stored.
      #
      # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct whose
      #   declared attributes and defaults `state` is hydrated against
      # @param state [Hash{Symbol => Object}] the raw stored (or partial) attribute values
      # @return [Hash{Symbol => Object}] `state` coerced through every declared attribute,
      #   with any missing declared-default attribute filled in
      def self.hydrate_with_defaults(aggregate, state)
        hydrated = Value.hydrate(aggregate, state)
        defaults(aggregate).each do |name, value|
          hydrated[name] = value unless value.nil? || hydrated.key?(name)
        end
        hydrated
      end

      # Builds a fresh record's starting state: every declared attribute's
      # default value, an empty frozen Array for a `list_of` attribute, and
      # the lifecycle field's declared starting value when `aggregate` has one.
      #
      # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct whose
      #   declared attributes and lifecycle are read
      # @return [Hash{Symbol => Object}] the default state, keyed by attribute name
      def self.defaults(aggregate)
        state = aggregate.attributes.to_h do |attr|
          # Frozen, like a list that has had something appended to it.
          # An untouched list is the easiest one to miss and the easiest
          # to mutate: nothing has replaced it yet, so a caller pushing
          # into it writes straight into the aggregate's own state.
          [attr.name, attr.list? ? Freezer.deep([]) : default_for(aggregate, attr)]
        end
        state[aggregate.lifecycle.field.to_sym] = aggregate.lifecycle.default if aggregate.lifecycle
        state
      end

      # Resolves one attribute's default value: its own declared `default:`
      # if it has one, otherwise a value object built entirely from its own
      # members' defaults, when every member declares one.
      #
      # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct
      #   `attribute` belongs to
      # @param attribute [Bluebook::Attribute] the attribute to resolve a default for
      # @return [Runtime::Value, Object, nil] the coerced default value; nil when
      #   `attribute` declares no default and either names no value object or names
      #   one with a member that itself declares no default
      def self.default_for(aggregate, attribute)
        return Value.for_attribute(aggregate, attribute, attribute.default) unless attribute.default.nil?
        # An entity's members hydrate through the same path but an entity
        # declares no value objects of its own — nothing to default-build.
        return nil unless aggregate.respond_to?(:value_object)

        value_object = aggregate.value_object(attribute.type)
        return nil unless value_object&.attributes&.all? { |field| !field.default.nil? }

        Value.build(value_object, {}, aggregate)
      end

      # Reads one state field by name.
      #
      # @param name [String, Symbol] the declared attribute name to read
      # @return [Object, nil] the field's current value; nil if `name` is not a key
      #   of `state`
      def [](name) = @state[name.to_sym]

      # Reports whether `state` holds a value for `name`.
      #
      # @param name [String, Symbol] the declared attribute name to check
      # @return [Boolean] true if `state` has a key for `name`
      def key?(name) = @state.key?(name.to_sym)

      # Writes one state field by name.
      #
      # @param name [String, Symbol] the declared attribute name to write
      # @param value [Object] the value to store
      # @return [Object] `value`, unchanged
      def []=(name, value)
        @state[name.to_sym] = value
      end

      def method_missing(name, *args)
        return @state[name] if @state.key?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @state.key?(name) || super
      end

      # Renders this record's wire/storage shape, state plus its identity.
      #
      # `id: @id` last, not first — see Facade::Handle#to_h's own comment
      # for the full story (the same fix, landed there first): an
      # aggregate free to declare its own attribute literally named `id`
      # (BurningManPrep's `Item`, `attribute :id, ItemId`) has that
      # attribute's own wrapped value object sitting in `@state[:id]` —
      # merging `@state` on top of `{ id: @id }` let it silently clobber
      # the correct bare identity. `@id` merged last always wins.
      #
      # @return [Hash{Symbol => Object}] `state`, with `id` merged in last
      def to_h = @state.merge(id: @id)

      # Copies this record, deep enough that a mutation on the copy cannot
      # reach the original's own state.
      #
      # A copy a mutation may touch. Every adapter but Memory hands `find`
      # a freshly-decoded Instance already; Memory's holds the record it
      # eventually saves — the same state Hash, aliased. Before `ensures`
      # existed, nothing could refuse between apply_mutations and save, so
      # that aliasing was invisible: a dispatch either ran to completion or
      # raised before touching state at all. `ensures` is the first refusal
      # to sit after mutation, and it found the bug the moment it did — an
      # in-memory record left half-mutated by a dispatch that then refused.
      # `command_interpreter`/`entity_interpreter` hydrate an existing
      # record through this, never through the adapter's own return value
      # directly, so a refused ensures leaves the stored record untouched
      # regardless of which adapter is holding it.
      #
      # @return [Runtime::Instance] a copy of this record, with its own state Hash
      def dup
        copy = super
        copy.state = @state.dup
        copy
      end

      def inspect
        fields = @state.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
        "#<#{@aggregate.hecks_name} #{@id} #{fields}>"
      end

      private

      # M17 — a composite identity (`identity_heads.size > 1`, e.g.
      # `identified_by :branch_code, :box_number`) has no single
      # `identified_by` to fall back to `:id` for — `@aggregate.identified_by`
      # is nil the moment there is more than one head (`Behaviour::Identified
      # #derive_identity`), so the single-head branch below never runs for
      # it at all. Without this, a creating command that declares those heads
      # as ordinary attributes but doesn't also `sets` them (redundant with
      # the identity the command's own args already named) would persist
      # every head as nil — the id correctly naming the record, but the
      # record's own attributes forgetting what named it.
      #
      # Filled from `args`, never from splitting `@id` back apart — the
      # same reason the single-head branch below won't guess a multi-path
      # identifier from its joined string: `@id` is a display key, not a
      # reversible serialization, and a composite's own separator can
      # collide with a part's own text. `args` is only offered by a fresh
      # creation (`Instance.new`'s own `args:` comment); an existing record
      # read back from storage has no args to lean on, and doesn't need
      # one since a correctly-persisted record already carries its own
      # heads.
      def materialize_identity!(args = nil)
        return materialize_composite_identity!(args) if @aggregate.identity_heads.size > 1

        identity  = @aggregate.identified_by || :id
        attribute = @aggregate.attribute(identity)
        return unless attribute && @state[identity].nil?
        # Several paths under one head mean the identifier is a display key,
        # not a reversible serialization of the structured value object. A
        # creating command supplies that object explicitly; persisted state
        # hydrates it from storage. Never guess by splitting the joined id.
        return if @aggregate.identity_heads.one? && @aggregate.identity_paths.size > 1

        @state[identity] = Value.from_identifier(@aggregate, attribute, @id)
      end

      def materialize_composite_identity!(args)
        return unless args

        @aggregate.identity_paths.each do |path|
          head = path.to_s.split(".").first.to_sym
          attribute = @aggregate.attribute(head)
          next unless attribute && @state[head].nil?

          raw = Identity.from(@aggregate, args, path, value_owner: @aggregate)
          next if raw.nil?

          @state[head] = Value.from_identifier(@aggregate, attribute, raw)
        end
      end
    end
  end
end

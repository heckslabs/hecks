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
      # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct this record's
      #   state is shaped by
      # @param id [String, nil] the record's identity, or nil when none has resolved yet
      # @param state [Hash{Symbol => Object}, nil] the record's stored state, hydrated with
      #   defaults; nil builds a fresh record from `self.class.defaults`
      # @param args [Hash, nil] the original command payload, for materializing a fresh
      #   record's own identity attribute(s); nil for a record read back from storage
      def initialize(aggregate:, id:, state: nil, args: nil)
        @aggregate = aggregate
        @id        = id
        # Inside a persistence adapter call this refuses undecoded stored
        # state (Ports::Persistence::CodecBoundary); everywhere else, no-op.
        Ports::Persistence::CodecBoundary.check_state!(aggregate, state) if state
        @state     = state ? self.class.hydrate_with_defaults(aggregate, state) : self.class.defaults(aggregate)
        @version   = nil
        materialize_identity!(args)
      end

      # Fills a stored record's state with any declared default it predates.
      #
      # Loading existing state runs the same default-fill a fresh instance
      # gets: an attribute the record predates — a newly-required field
      # with a declared default:, a list added since the record was
      # written — arrives filled instead of nil. Only declared defaults
      # fill in; an attribute with no default stays absent, exactly as
      # stored.
      #
      # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct declaring the
      #   attributes and their defaults
      # @param state [Hash{Symbol => Object}] the stored state to fill in
      # @return [Hash{Symbol => Object}] `state`, hydrated (`Value.hydrate`) and with any
      #   missing default filled in
      def self.hydrate_with_defaults(aggregate, state)
        hydrated = Value.hydrate(aggregate, state)
        defaults(aggregate).each do |name, value|
          hydrated[name] = value unless value.nil? || hydrated.key?(name)
        end
        hydrated
      end

      # Builds a fresh record's state: every declared attribute at its default, plus the
      # lifecycle field's own default when the construct declares a lifecycle.
      #
      # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct to build
      #   default state for
      # @return [Hash{Symbol => Object}] every declared attribute name mapped to its default
      #   value (a frozen `[]` for a list attribute)
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

      # Resolves one attribute's default value: its declared `default:`, or a value
      # object's own built-in default when every one of its fields has one.
      #
      # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct declaring
      #   `attribute`
      # @param attribute [Bluebook::Attribute] the attribute to default
      # @return [Object, nil] the coerced declared default; a value object built from its own
      #   defaulted fields when the attribute names one and every field defaults; otherwise nil
      def self.default_for(aggregate, attribute)
        return Value.for_attribute(aggregate, attribute, attribute.default) unless attribute.default.nil?
        # An entity's members hydrate through the same path but an entity
        # declares no value objects of its own — nothing to default-build.
        return nil unless aggregate.respond_to?(:value_object)

        value_object = aggregate.value_object(attribute.type)
        return nil unless value_object&.attributes&.all? { |field| !field.default.nil? }

        Value.build(value_object, {}, aggregate)
      end

      # Reads one field of the record's state.
      #
      # @param name [String, Symbol] the field name
      # @return [Object, nil] the field's value, or nil if `name` is not a key of `state`
      def [](name) = @state[name.to_sym]

      # Reports whether the record's state has a field named `name`.
      #
      # @param name [String, Symbol] the field name
      # @return [Boolean] true if `state` has that key
      def key?(name) = @state.key?(name.to_sym)

      # Writes one field of the record's state.
      #
      # @param name [String, Symbol] the field name
      # @param value [Object] the value to store
      # @return [Object] `value`
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

      # `id: @id` last, not first — see Facade::Handle#to_h's own comment
      # for the full story (the same fix, landed there first): an
      # aggregate free to declare its own attribute literally named `id`
      # (BurningManPrep's `Item`, `attribute :id, ItemId`) has that
      # attribute's own wrapped value object sitting in `@state[:id]` —
      # merging `@state` on top of `{ id: @id }` let it silently clobber
      # the correct bare identity. `@id` merged last always wins.
      #
      # @return [Hash{Symbol => Object}] the record's state with `:id` merged in last
      def to_h = @state.merge(id: @id)

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
      # @return [Hecks::Runtime::Instance] a shallow copy, with its own top-level `state` Hash
      #   (not aliased to this instance's)
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
      # it at all. A creating command that declares those heads as ordinary
      # attributes but doesn't also `sets` them (redundant with the identity
      # the command's own args already named) would otherwise persist every
      # head as nil — the id correctly names the record, but the record's
      # own attributes would forget what named it.
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

require_relative "value"
require_relative "identity"
require_relative "../ports/persistence/codec_boundary"

module Hecks
  module Runtime
    # One aggregate or entity record's runtime state: declared attributes plus `id` and `version`.
    # `to_h` is the wire/storage shape, with `id` merged last so an attribute named `id` loses.
    class Instance
      attr_reader :aggregate, :id
      attr_accessor :state
      # Optimistic-concurrency version stamped by a CAS-capable adapter; not domain state.
      # Left out of `to_h` and `[]` on purpose; nil means no CAS was attempted.
      attr_accessor :version

      # `args` is the creation payload, used only to fill a composite identity's heads.
      # `hydrate: false` skips the default re-walk for an already-hydrated, validated state,
      # keeping a `list_of` entity's Nth save O(1) rather than O(N).
      def initialize(aggregate:, id:, state: nil, args: nil, hydrate: true)
        @aggregate = aggregate
        @id        = id
        # Inside a persistence adapter call this refuses undecoded stored state.
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

      # Hydrates `state` and fills declared defaults for attributes the record predates.
      def self.hydrate_with_defaults(aggregate, state)
        hydrated = Value.hydrate(aggregate, state)
        defaults(aggregate).each do |name, value|
          hydrated[name] = value unless value.nil? || hydrated.key?(name)
        end
        hydrated
      end

      # Builds a fresh record's starting state: declared defaults, empty lists, lifecycle start.
      def self.defaults(aggregate)
        state = aggregate.attributes.to_h do |attr|
          # Frozen so pushing into an untouched list cannot write into the aggregate's state.
          [attr.name, attr.list? ? Freezer.deep([]) : default_for(aggregate, attr)]
        end
        state[aggregate.lifecycle.field.to_sym] = aggregate.lifecycle.default if aggregate.lifecycle
        state
      end

      # Resolves an attribute's default, building a value object from its members' defaults.
      def self.default_for(aggregate, attribute)
        return Value.for_attribute(aggregate, attribute, attribute.default) unless attribute.default.nil?
        # An entity declares no value objects of its own.
        return nil unless aggregate.respond_to?(:value_object)

        value_object = aggregate.value_object(attribute.type)
        return nil unless value_object&.attributes&.all? { |field| !field.default.nil? }

        Value.build(value_object, {}, aggregate)
      end

      # Reads one state field by name.
      def [](name) = @state[name.to_sym]

      # Reports whether `state` holds a value for `name`.
      def key?(name) = @state.key?(name.to_sym)

      # Writes one state field by name.
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

      # State plus identity, `id` merged last so a declared attribute named `id` cannot clobber it.
      def to_h = @state.merge(id: @id)

      # Copies this record with its own state Hash, so a refused dispatch spares the original.
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

      # A composite identity has no single head, so each head is filled from `args`.
      # Never split `@id`: it is a display key and a part's text can contain the separator.
      def materialize_identity!(args = nil)
        return materialize_composite_identity!(args) if @aggregate.identity_heads.size > 1

        identity  = @aggregate.identified_by || :id
        attribute = @aggregate.attribute(identity)
        return unless attribute && @state[identity].nil?
        # Several paths under one head make the id a display key, not reversible; never split it.
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

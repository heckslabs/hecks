require_relative "value"

module Hecksagain
  module Runtime
    class Instance
      attr_reader :aggregate, :id
      attr_accessor :state

      def initialize(aggregate:, id:, state: nil)
        @aggregate = aggregate
        @id        = id
        @state     = state ? self.class.hydrate_with_defaults(aggregate, state) : self.class.defaults(aggregate)
        materialize_identity!
      end

      # Loading existing state runs the same default-fill a fresh instance
      # gets: an attribute the record predates — a newly-required field
      # with a declared default:, a list added since the record was
      # written — arrives filled instead of nil. Only declared defaults
      # fill in; an attribute with no default stays absent, exactly as
      # stored.
      def self.hydrate_with_defaults(aggregate, state)
        hydrated = Value.hydrate(aggregate, state)
        defaults(aggregate).each do |name, value|
          hydrated[name] = value unless value.nil? || hydrated.key?(name)
        end
        hydrated
      end

      def self.defaults(aggregate)
        state = aggregate.attributes.each_with_object({}) do |attr, acc|
          acc[attr.name] = attr.list? ? [] : default_for(aggregate, attr)
        end
        state[aggregate.lifecycle.field.to_sym] = aggregate.lifecycle.default if aggregate.lifecycle
        state
      end

      def self.default_for(aggregate, attribute)
        return Value.for_attribute(aggregate, attribute, attribute.default) unless attribute.default.nil?
        # An entity's members hydrate through the same path but an entity
        # declares no value objects of its own — nothing to default-build.
        return nil unless aggregate.respond_to?(:value_object)

        value_object = aggregate.value_object(attribute.type)
        return nil unless value_object && value_object.attributes.all? { |field| !field.default.nil? }

        Value.build(value_object, {})
      end

      def [](name) = @state[name.to_sym]

      def key?(name) = @state.key?(name.to_sym)

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

      def to_h = { id: @id }.merge(@state)

      def inspect
        fields = @state.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
        "#<#{@aggregate.hecks_name} #{@id} #{fields}>"
      end

      private

      def materialize_identity!
        identity  = @aggregate.identified_by || :id
        attribute = @aggregate.attribute(identity)
        return unless attribute && @state[identity].nil?

        @state[identity] = Value.from_identifier(@aggregate, attribute, @id)
      end
    end
  end
end

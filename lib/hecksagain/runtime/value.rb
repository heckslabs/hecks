require "json"
require_relative "../rendering"
require_relative "value/invariant_violation"
require_relative "value/coercion"
require_relative "value/admission"

module Hecksagain
  module Runtime
    # A typed value object in hand: frozen fields, read by name. How one is
    # MADE — coerced from a raw argument, checked against its declared
    # numeric types, patterns and closed sets — is the class-side engine in
    # value/coercion.rb and value/admission.rb, extended here so the door
    # stays where it always was: `Value.for`, `Value.build`.
    class Value
      extend Coercion
      extend Admission

      attr_reader :value_object

      def initialize(value_object, fields)
        @value_object = value_object
        @fields       = fields.transform_keys(&:to_sym).freeze
      end

      def type_name = @value_object.hecks_name
      def [](field) = @fields[field.to_sym]
      def key?(field) = @fields.key?(field.to_sym)
      def to_h = @fields.transform_values { |value| self.class.materialize(value) }
      def to_json(*) = JSON.generate(to_h)

      def ==(other)
        other.is_a?(self.class) && other.type_name == type_name && other.to_h == to_h
      end

      def with(field, value)
        self.class.build(@value_object, @fields.merge(field.to_sym => value))
      end

      def self.materialize(value)
        case value
        when self then value.to_h
        when Array then value.map { |item| materialize(item) }
        when Hash then value.transform_values { |item| materialize(item) }
        else value
        end
      end

      # REDUCES AN APPEND-ONLY SUB-LOG TO ITS CURRENT STATE — the same
      # "a later fact supersedes an earlier one" reduction this runtime
      # already performs replaying an AGGREGATE's own command history
      # into its current attributes, applied here to a single `list_of`
      # FIELD acting as its own miniature append-only log (a placement
      # history, a tombstone-style soft-delete list, a versioned
      # setting). `rows` is what a `list_of` attribute hands back — an
      # Array of `Value`, in append order — and `key` names the field
      # that identifies "the same logical thing" across entries.
      #
      # GROUPING ONLY, NEVER INTERPRETATION. What counts as "removed,"
      # how to order what survives — that meaning belongs to whichever
      # domain declared the field, never here: a generic reduction that
      # started guessing domain semantics would need to keep guessing
      # forever, once per shape of "gone" any caller ever invents. The
      # caller filters and sorts the result; this only groups it.
      def self.latest_by(rows, key)
        rows.each_with_object({}) { |row, latest| latest[row.public_send(key)] = row }.values
      end

      def method_missing(name, *args)
        return @fields[name] if @fields.key?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @fields.key?(name) || super
      end
    end
  end
end

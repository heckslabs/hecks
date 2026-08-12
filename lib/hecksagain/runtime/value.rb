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

      # FROZEN THROUGH, not just on top.
      #
      # `@fields.freeze` alone stops a key being added or removed and
      # nothing else: the String, Array or Hash a field HOLDS stays
      # mutable, so `vo[:value] << "!"` edits a value object in place —
      # demonstrated on a real dispatch before this was written, not
      # supposed. Same shape as the three freezing bugs already fixed
      # (list attributes, the event log, query rows), where the container
      # was frozen and the contents were not.
      #
      # A value object is the one thing in the domain that has no
      # identity to change over — `with` already answers a NEW one rather
      # than mutating — so freezing it through is what it always claimed
      # to be.
      def initialize(value_object, fields)
        @value_object = value_object
        @fields       = Freezer.deep(fields.transform_keys(&:to_sym))
        freeze
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

      # `materialize`, but a single-attribute value object (`sole_attribute`
      # — [[feedback_name_the_scalar_field]]) recurses into its own bare
      # field instead of building `{field: ...}` — a Board's own `label`
      # unwraps to `"Kanban"`, not `{value: "Kanban"}`. NOT a replacement
      # for `materialize` itself: every existing report/query/command
      # caller keeps the wrapped shape it already depends on (Banking's
      # own `CustomerPortfolio` reads `payment[:amount][:cents]`, and
      # changing that out from under it would be a real breaking change,
      # not a bug fix). This is read_model_interpreter.rb's own opt-in,
      # used ONLY for a `group_by`-declared head's own rows — grouping
      # needs a real scalar to key by regardless, so a report already
      # asking for that gets the unwrap for free.
      def self.materialize_unwrapped(value)
        case value
        when self
          sole = value.value_object.sole_attribute
          return materialize_unwrapped(value[sole.name]) if sole

          # NOT `value.to_h` — `Value#to_h` materializes each field through
          # plain `materialize`, so a VO nested inside a multi-attribute VO
          # would already be a plain Hash by the time this method ever saw
          # it, and never reach the `when self` branch above. Read each
          # field straight off `value` instead, so recursion actually
          # happens through THIS method the whole way down.
          value.value_object.attributes.to_h { |attr| [attr.name, materialize_unwrapped(value[attr.name])] }
        when Array then value.map { |item| materialize_unwrapped(item) }
        when Hash then value.transform_values { |item| materialize_unwrapped(item) }
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

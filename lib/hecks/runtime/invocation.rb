require_relative "errors"
require_relative "refusal_wording"
require_relative "routing"
require_relative "invocation_builder"
require_relative "../rendering"

module Hecks
  module Runtime
    # One dispatch, as data: the verb, the resolved receiver (`target`, a
    # `Routing::Envelope` or nil), and every fact the caller offered or didn't.
    Invocation = Data.define(:verb, :target, :facts)

    # Adds the fact wrappers and builders for an `Invocation`.
    class Invocation
      extend InvocationBuilder

      # A fact the caller offered with a real (non-nil) value.
      Present = Data.define(:value) do
        def inspect = "#<Invocation::Present #{value.inspect}>"
        alias_method :to_s, :inspect
      end

      # The class of the two frozen marker singletons below — never
      # instantiated anywhere else.
      class Marker
        def initialize(name)
          @name = name
          freeze
        end

        def inspect = "Invocation::#{@name}"
        alias to_s inspect
      end
      private_constant :Marker

      Absent = Marker.new("Absent")
      Null   = Marker.new("Null")

      # Dupes and freezes `facts` so a caller can't mutate them after
      # construction.
      def initialize(verb:, target:, facts:)
        super(verb: verb, target: target, facts: facts.dup.freeze)
      end

      # The fact recorded under `name`; `Absent` when never offered (and not
      # declared either).
      def fact(name) = facts.fetch(name, Absent)

      def present?(name) = fact(name).is_a?(Present)

      def null?(name)    = fact(name).equal?(Null)

      def absent?(name)  = fact(name).equal?(Absent)

      # A Present fact's value (nil for Null). Raises for Absent rather than
      # returning nil, so "never offered" isn't conflated with an explicit null.
      def value(name)
        case (found = fact(name))
        when Present then found.value
        when Null then nil
        else raise KeyError, "#{verb} was not given #{name.inspect}"
        end
      end

      # The offered facts as a plain Hash, in offered order: Absent keys
      # omitted, Null mapped to nil. A fresh Hash every call.
      def to_args
        facts.each_with_object({}) do |(name, found), args|
          next if found.equal?(Absent)

          args[name] = found.equal?(Null) ? nil : found.value
        end
      end
    end
  end
end

require_relative "behaviour/attribute"
require_relative "../ir"
require_relative "../vocabulary"
require_relative "../naming"

module Hecks
  module Bluebook
    # One declared field on a construct: name, type, list, default, optional, pattern
    # and the closed set it `admits`.
    class Attribute
      include Hecks::IR
      include Behaviour::Attribute

      emits_ir(
        name:         :name,
        type:         -> { @type.to_s },
        list:         :list?,
        default:      :default,
        optional:     :optional?,
        pattern:      :pattern,
        admits:       :admits,
        relationship: :relationship
      )

      attr_reader :name, :type, :default, :pattern, :admits, :relationship

      # A Reference is kept as itself; every other type is a name.
      #
      # @param name [Symbol, String] the attribute's name
      # @param type [Module, Bluebook::Reference, String, Symbol] a bare constant, a Reference,
      #   or already-spelled text
      # @param list [Boolean] whether this attribute holds a list of values rather than one
      # @param default [Object, nil] the value a new record starts with when none is given
      # @param optional [Boolean] whether a command may omit this attribute
      # @param pattern [String, nil] a regex source the value must match (`PatternSubset`)
      # @param admits [String, nil] an aggregate-qualified closed-set name for the value
      # @param relationship [Symbol, nil] the DSL word that minted this attribute, or `nil`
      def initialize(name:, type:, list: false, default: nil, optional: false, pattern: nil,
                     admits: nil, relationship: nil)
        @name     = name.to_sym
        @type     = spell(type)
        @list     = list
        @default  = default
        @optional = optional
        @pattern  = pattern
        @admits   = admits&.to_s
        @relationship = relationship&.to_s
      end

      # A bare constant in a bluebook is a name, even when Ruby has heard of it.
      #
      # `Facade::Surface` installs aggregate names as top-level constants, which would win
      # over the `const_missing` resolver and silently rebind the attribute. Demodulising
      # spells `:Target` and `QualityControl::Target` the same.
      def spell(type)
        return type if type.is_a?(Reference)
        return Naming.demodulise(type) if type.is_a?(Module)

        type.to_s
      end
      private :spell

      # Pinned by spec/vocabulary_conformance, which holds `Primitive`'s members to this list.
      PRIMITIVES = Hecks::Vocabulary.fetch("Primitive")
    end
  end
end

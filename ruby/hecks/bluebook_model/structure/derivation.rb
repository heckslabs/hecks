module Hecks
  module BluebookModel
    module Structure

    # Hecks::BluebookModel::Structure::Derivation
    #
    # A pure, side-effect-free method declared on a value object over its own
    # fields + params -- the BEHAVIOUR half of a rich value object (Evans : value
    # objects are the core). A value object is "an entity minus identity" ; because
    # it is immutable, its behaviour is pure functions returning booleans / new
    # value objects, never mutation, lifecycle, or identity.
    #
    # A derivation is callable from a command's `given` or an invariant :
    #   value_object "Money" do
    #     attribute :cents, Integer, default: 0
    #     derive :zero?,   Boolean do cents == 0 end
    #     derive :covers?, Boolean do |other| cents >= other.cents end
    #   end
    #   # given { balance.covers?(amount) }
    #
    # PARITY : the canonical IR dumps name + return_type + param NAMES only ; the
    # body is a Proc whose source is unrecoverable, so each runtime evaluates the
    # predicate from its own parse (the identical contract Structure::Invariant uses).
    #
    #   d = Derivation.new(name: "covers?", return_type: "Boolean", params: ["other"],
    #                      block: proc { |other| cents >= other.cents })
    #   d.name         # => "covers?"
    #   d.return_type  # => "Boolean"
    #   d.params       # => ["other"]
    #
    class Derivation
      # @return [String] the method name (e.g. "covers?", "zero?"). A trailing
      #   "?" is part of the name, matching the predicate-method convention.
      attr_reader :name

      # @return [String] the declared return type token (e.g. "Boolean").
      #   Boolean derivations evaluate as predicates ; others as expressions.
      attr_reader :return_type

      # @return [Array<String>] the block parameter NAMES (`|other|` => ["other"]).
      #   A param's TYPE is not declared -- it is whatever value binds at the call site.
      attr_reader :params

      # @return [Proc, nil] the callable body, evaluated via instance_exec against
      #   a scope of the receiver's own fields + the bound params.
      attr_reader :block

      # Creates a new Derivation IR node.
      #
      # @param name [String] the method name
      # @param return_type [String] the declared return type token
      # @param params [Array<String>] block parameter names
      # @param block [Proc, nil] the pure body
      #
      # @return [Derivation] a new Derivation instance
      def initialize(name:, return_type:, params: [], block: nil)
        @name = name
        @return_type = return_type
        @params = params
        @block = block
      end
    end
    end
  end
end

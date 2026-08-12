require_relative "behaviour/domain_port"

module Hecksagain
  class Bluebook
    # THE PRIMARY/DRIVING HALF OF HEXAGONAL ARCHITECTURE (Cockburn) — called
    # BY an adapter living outside the bluebook entirely, never by the
    # domain calling out. That is already `Hecks.port` (persistence,
    # projection, extraction, loading) plus `Ports::*` : the secondary/
    # driven half, unchanged by this.
    #
    # An operation carries no `given`/`ensures`/`then_set` — a port is the
    # anti-corruption boundary that turns an external call into a fact in
    # this domain's own vocabulary, not a second place business rules live.
    # Those stay on whatever command a `policy` triggers in reaction to the
    # event an operation emits.
    class PortOperation
      include Hecksagain::IR
      include Behaviour::PortOperation

      emits_ir(name: :hecks_name, attributes: many(:attributes), emits: :emits)

      attr_reader :hecks_name, :attributes, :emits

      def initialize(name:, attributes: [], emits: [])
        @hecks_name = name.to_s
        @attributes = attributes
        @emits      = emits
        @attributes_by_name = attributes.to_h { |attribute| [attribute.name, attribute] }
      end

      # No root reference of its own — unlike a command, every attribute
      # EQUALLY describes the payload, including whichever one identifies
      # the record its emitted event belongs to. Kept only so
      # CommandInterpreter::ArgumentGate's `reference_key` can ask for it
      # without learning this isn't a command.

    end

    # A named group of operations an aggregate (or, later, a chapter)
    # exposes to whatever adapter calls in — the contract that today lives
    # only as a bare `verb`/`signal` pair in a standalone `.port` file.
    # Superseding those is the goal ; for now they keep working untouched,
    # and this is additive.
    class DomainPort
      include Hecksagain::IR
      include Behaviour::DomainPort

      emits_ir(name: :name, operations: many(:operations))

      attr_reader :name, :operations

      def initialize(name:, operations: [])
        @name       = name.to_s
        @operations = operations
      end


    end
  end
end

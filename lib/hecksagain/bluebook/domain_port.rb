require_relative "behaviour/domain_port"

module Hecksagain
  module Bluebook
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

      attr_reader :hecks_name, :attributes, :emits, :direction, :answers, :refuses

      # TWO DIRECTIONS THROUGH ONE DOOR.
      #
      # `:inbound` is what this class has always been — `tells`, spelled
      # `operation` before it had a twin: an external fact arriving, turned
      # into this domain's own event. It emits and that is all; there is no
      # channel back to whoever called.
      #
      # `:outbound` is `asks` — the domain wanting something from outside
      # and having to live with either answer. It names BOTH: `answers` for
      # what the adapter came back with, `refuses` for what it said instead.
      # Naming only the happy one would put the failure somewhere the model
      # cannot see, which is the whole reason a boundary is worth modelling.
      def initialize(name:, attributes: [], emits: [], direction: :inbound, answers: nil, refuses: nil)
        @hecks_name = name.to_s
        @attributes = attributes
        @emits      = emits
        @direction  = direction.to_sym
        @answers    = answers
        @refuses    = refuses
        @attributes_by_name = attributes.to_h { |attribute| [attribute.name, attribute] }
      end

      def outbound? = @direction == :outbound
      def inbound?  = @direction == :inbound

      # No root reference of its own — unlike a command, every attribute
      # EQUALLY describes the payload, including whichever one identifies
      # the record its emitted event belongs to. Kept only so
      # CommandInterpreter::ArgumentGate's `reference_key` can ask for it
      # without learning this isn't a command.

      # `direction`/`answers`/`refuses` are deliberately OUTSIDE `emits_ir`'s
      # declared shape and added here only for an outbound operation — an
      # ordinary inbound one (`tells`, still spelled `operation` everywhere
      # in the existing corpus) keeps the EXACT prior IR shape, byte for
      # byte. Pizzas' `PaymentGateway` port is inbound-only and is checked
      # against `hecks-parse`'s own Rust output for byte-identity
      # (parser_parity_spec.rb) — the Rust side has no notion of `asks` yet,
      # so an unconditional new key here would break that parity for a
      # domain that never asked for the feature. Only a chapter that
      # actually declares `asks` (this extraction's own QualityControl
      # ledger, not yet in any Rust-parity corpus) pays for it.
      def to_h
        shape = super
        return shape if inbound?

        shape.merge(direction: @direction.to_s, answers: @answers, refuses: @refuses)
      end
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

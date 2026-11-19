# frozen_string_literal: true

require "hecks/roundhouse/adapters/metering"
require_relative "looking/view"
require_relative "looking/marks"
require_relative "looking/delegate_look"

module Hecks
  module Adapters
    # The `Looking` port's adapter for Signalbox's `Beat` (ADR 0222, phase 2, the shadow): one look
    # for the pressure beat. It answers the copy's view against main, the machine as Roundhouse's
    # meter reads it, the marks and draws of the Signalbox world, and the subjects of Delegate's
    # last fill and shed. It reads only, and compares no reading with a mark: the bluebook does.
    class Looking
      # A look that could not read the machine.
      class Unlooked < StandardError; end

      # @param registry [Runtime::Registry, nil] whose Signalbox world and Delegate records it reads
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins for the outside: `view:`, `machine:`, `marks:` and
      #   `delegate:`, each a callable answering the hash its part would
      # @param root [String, nil] the checkout the beat runs from
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        live = { view: -> { View.new(root || Dir.pwd).facts }, machine: -> { Metering.new(registry: registry).machine_facts },
                 marks: -> { Marks.new(registry).facts }, delegate: -> { DelegateLook.new(registry).facts } }
        @view, @machine, @marks, @delegate = live.map { |part, read| settings.fetch(part, read) }
      end

      # @param held [Hash] the `Beat` record: `beat`
      # @return [Hash{Symbol => Hash}] each answered field as `{ value: }`
      # @raise [Unlooked] when the machine's capacity cannot be read
      def look(**held)
        beat = held[:beat].is_a?(Hash) ? held[:beat][:value] : held[:beat]
        machine = @machine.call
        raise Unlooked, "the machine's memory could not be read" unless machine[:capacity_mb].to_i.positive?

        wrap(beat: beat, **@view.call, **reading(machine), **@marks.call, **rulings(beat), **@delegate.call)
      end

      private

      # A reading is taken as it is looked at, so its age is nought.
      def reading(machine)
        { capacity: machine[:capacity_mb], used: machine[:used_mb], load: machine[:load], cores: machine[:cores], age: 0 }
      end

      def rulings(beat) = { fill_ruling: "#{beat}:fill", shed_ruling: "#{beat}:shed" }

      def wrap(facts) = facts.transform_values { |fact| { value: fact } }
    end
  end
end

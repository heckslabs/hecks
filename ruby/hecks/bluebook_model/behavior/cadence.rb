# Hecks::BluebookModel::Behavior::Cadence
#
# [antibody-exempt: ruby/hecks/bluebook_model/behavior/cadence.rb — IR
#  node for the `cadence` bluebook keyword. The Ruby IR layer is
#  necessarily code (kernel floor — bluebook describes the shape, IR
#  classes hold the parsed-shape-as-Ruby-objects). Mirror of the
#  process_manager.rb IR node ; identical Trikaya-floor justification.]
#
# IR node for the +cadence+ DSL keyword — declarative scheduled dispatch.
# A cadence carries an interval (e.g. "1s") and one or more commands to
# dispatch each tick. Body's existing given clauses gate which dispatches
# actually mutate state ; the cadence is purely the scheduled trigger.
#
# Replaces the imperative `while true ; sleep 1 ; dispatch X ; done` loop
# in shells like body/mindstream.sh. The bluebook declaration says WHAT
# fires WHEN ; the runtime runs the loop.
#
#   cadence "BodyTick" do
#     every "1s"
#     dispatch "Consciousness.ElapsePhase", name: "consciousness"
#     dispatch "Tick.MindstreamTick",       name: "tick"
#   end
#
module Hecks
  module BluebookModel
    module Behavior
      class Cadence
        # One scheduled dispatch — command name + literal kwarg map.
        Dispatch = Struct.new(:command_name, :attrs, keyword_init: true) do
          def initialize(*)
            super
            self.attrs ||= {}
          end
        end

        attr_reader :name, :interval, :dispatches, :description

        # @param name [String] PascalCase cadence name
        # @param interval [String] cron-like interval (e.g. "1s", "5m", "1h")
        # @param dispatches [Array<Dispatch>] declared dispatches in order
        # @param description [String, nil] optional description
        def initialize(name:, interval:, dispatches:, description: nil)
          @name = name.to_s
          @interval = interval.to_s
          @dispatches = dispatches
          @description = description
        end
      end
    end
  end
end

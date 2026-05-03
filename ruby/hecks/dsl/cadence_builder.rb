# Hecks::DSL::CadenceBuilder
#
# [antibody-exempt: ruby/hecks/dsl/cadence_builder.rb — DSL parser for
#  the `cadence` bluebook keyword. The parser of bluebook is kernel
#  floor (Trikaya — the parser of bluebook can't itself be bluebook).
#  Mirror of process_manager_builder.rb shape ; same justification.]
#
# DSL builder for the +cadence+ keyword — declarative scheduled dispatch.
# Captures the interval (e.g. "1s") + one or more `dispatch "Cmd", **kwargs`
# lines and builds a +BluebookModel::Behavior::Cadence+ IR node.
#
#   cadence "BodyTick" do
#     every "1s"
#     dispatch "Consciousness.ElapsePhase", name: "consciousness"
#     dispatch "Tick.MindstreamTick",       name: "tick"
#   end
#
# Validation (raised as +ArgumentError+ at +build+):
#
# 1. +every+ must be a String matching `/^\d+[smhd]$/`
# 2. at least one +dispatch+ must be declared
# 3. each dispatch's command name must contain a `.` (qualified Aggregate.Command)
#
module Hecks
  module DSL
    class CadenceBuilder
      Behavior = BluebookModel::Behavior

      include Describable

      # @param name [String] PascalCase cadence name (e.g. "BodyTick")
      def initialize(name)
        @name = name
        @interval = nil
        @dispatches = []
      end

      # Declare the tick interval. Cron-like single-unit string.
      #   every "1s"   — every second
      #   every "5m"   — every five minutes
      def every(interval)
        @interval = interval.to_s
      end

      # Declare one command to dispatch each tick. Multiple dispatches per
      # cadence fire in declaration order.
      def dispatch(command_name, **attrs)
        @dispatches << Behavior::Cadence::Dispatch.new(
          command_name: command_name.to_s,
          attrs: attrs.transform_keys(&:to_s)
        )
      end

      def build
        validate!
        Behavior::Cadence.new(
          name: @name,
          interval: @interval,
          dispatches: @dispatches,
          description: @description
        )
      end

      private

      def validate!
        validate_interval!
        validate_dispatches_present!
        validate_dispatches_qualified!
      end

      def validate_interval!
        if @interval.nil?
          raise ArgumentError,
                "cadence '#{@name}' missing required `every \"<interval>\"`"
        end
        return if @interval =~ /\A\d+[smhd]\z/
        raise ArgumentError,
              "cadence '#{@name}' interval must be `<digits><s|m|h|d>` " \
              "(e.g. \"1s\", \"5m\"), got #{@interval.inspect}"
      end

      def validate_dispatches_present!
        return unless @dispatches.empty?
        raise ArgumentError,
              "cadence '#{@name}' must declare at least one dispatch"
      end

      def validate_dispatches_qualified!
        @dispatches.each do |d|
          next if d.command_name.include?('.')
          raise ArgumentError,
                "cadence '#{@name}' dispatch command must be qualified " \
                "Aggregate.Command, got #{d.command_name.inspect}"
        end
      end
    end
  end
end

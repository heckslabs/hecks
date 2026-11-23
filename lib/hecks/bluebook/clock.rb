module Hecks
  module Bluebook
    # One `clock` a hecksagon declares (ADR 0184): its name, its one trigger, and the command it
    # dispatches with the arguments and role it dispatches them with.
    #
    # `trigger` is `:cron`, `:every` or `:at`, and `expression` is the literal the hecksagon gave
    # it. `zone` is a time zone name for a cron trigger, nil for UTC. `with` maps each argument to a
    # literal or to a symbol naming what the firing knows (`:fire_date`, `:fire_time`,
    # `:firing_id`).
    Clock = Struct.new(:name, :trigger, :expression, :zone, :command, :with, :role, keyword_init: true) do
      # @return [String] the aggregate the dispatched command belongs to, without its domain
      def aggregate_name = Naming.demodulise(command_parts.first)

      # @return [String] the dispatched command's own name
      def command_name = command_parts.last.to_s

      # @return [Array<String>] the aggregate and the command, split at the dot
      def command_parts = command.to_s.split(".", 2)

      # @return [Hash{Symbol => Object}] the arguments, empty when none
      def arguments = with || {}

      # @return [Hash{Symbol => Object}] the clock as plain data
      def to_h = super.merge(trigger: trigger.to_s, with: arguments.transform_values(&:to_s))
    end

    # What a clock's `with` symbol may name: the due instant's date and time in the clock's zone,
    # and an id made of the clock's name and that time.
    Clock::FIRING_VALUES = %i[fire_date fire_time firing_id].freeze
  end
end

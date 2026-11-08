# frozen_string_literal: true

require "hecks/hecks/adapters/dispatching"
require_relative "priority_report/backlog"
require_relative "priority_report/lines"

module Hecks
  module Adapters
    # The `PriorityReport` port's adapter for `Tickets::Work`: prints the open work items in the
    # order Dispatch starts them.
    #
    # It sorts nothing. The order is {Dispatching::WorkItems#planned}, the one ordering a roll
    # forward uses, and each planned item's reason to wait is {Dispatching::Plan}'s, built the way
    # `Dispatching` builds it. It reads and never writes.
    class PriorityReport
      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `work_items:`, `load:`, `cpus:` and `cap:` stand in for the queue
      #   and the machine
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standins = settings
      end

      # Says every open work item, in dispatch order, one line each.
      #
      # @param held [Hash] the query's `tier` (red, now, next, later or none), `limit` and `width`
      # @return [Hash{Symbol => String}] `text:` the header and the lines, ending in a newline
      def priority_report(**held)
        rows = Backlog.new(items, plan, @registry).rows
        lines = Lines.new(rows, started: items.started.size, cap: cap)
        { text: lines.text(tier: plain(held[:tier]), limit: plain(held[:limit]), width: plain(held[:width])) }
      end

      private

      def items = @standins[:work_items] || Dispatching::WorkItems.new(@registry)

      def machine = Dispatching::Settings.new(@registry, load: @standins[:load], cpus: @standins[:cpus], cap: @standins[:cap])

      def cap = machine.cap

      def plan
        Dispatching::Plan.new(items.planned, items.started, cap: cap, load: machine.load, max_load: machine.max_load,
                                                            frozen: machine.frozen)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end

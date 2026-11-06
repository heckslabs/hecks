require_relative "event"
require_relative "../freezer"

module Hecks
  module Runtime
    # A dispatcher whose `dispatch` is one line of the kernel's host protocol (ADR 0189), sent
    # through a `RustBuild::KernelClient`. The kernel runs the command and answers the events; this
    # class rebuilds each as a `Runtime::Event`, stamps it from the clock, and keeps it in `events`.
    #
    # Slice 1 of the thin-client plan answers `dispatch`, `dispatch_flat` and `events`. A refusal
    # the kernel answers is raised as {Refused}, carrying the kernel's own text; a dispatch from
    # inside a callback is raised as {NestedDispatch}, because the protocol has no rule for it yet.
    class KernelDispatcher
      # Raised when the kernel answers `ok: false`; the message is the kernel's error.
      class Refused < StandardError; end

      # Raised when a dispatch starts while another is still open on the same dispatcher.
      class NestedDispatch < StandardError; end

      # What one dispatch settled on, in the shape `Dispatcher::Result` shares for these two.
      Result = Struct.new(:verb, :events, keyword_init: true)

      # @return [Array<Runtime::Event>] every event the kernel announced, oldest first
      attr_reader :events

      # @param client [RustBuild::KernelClient] a connected client
      # @param clock [#call] answers the `occurred_at` stamp for a rebuilt event
      def initialize(client, clock: Event.method(:stamp))
        @client = client
        @clock = clock
        @events = []
        @lock = Mutex.new
      end

      # Runs one command in the kernel.
      #
      # @param verb [String] a qualified command, such as `Pizzas::Order.CreatePizza`
      # @param args [Hash] the command's facts, keyed by argument name
      # @return [Result] the verb and the events it announced
      # @raise [Refused] when the kernel refuses
      # @raise [NestedDispatch] when called while another dispatch is open
      def dispatch_flat(verb, args = {})
        raise NestedDispatch, "#{verb} was dispatched inside an open dispatch; not supported" if @lock.owned?

        @lock.synchronize { settle(verb, @client.dispatch(verb, args)) }
      end

      # @param verb [String] a qualified command
      # @param with [Hash, nil] the command's facts
      # @return [Result]
      # @raise [ArgumentError] when `to:` is given; the kernel is addressed by facts alone
      def dispatch(verb, to: nil, with: nil)
        raise ArgumentError, "to: is not supported through the kernel client" if to

        dispatch_flat(verb, with || {})
      end

      # Ends the kernel connection.
      #
      # @return [void]
      def close = @client.close

      private

      def settle(verb, answer)
        raise Refused, answer.fetch("error") unless answer["ok"]

        announced = answer.fetch("events").map { |wire| rebuild(wire) }
        @events.concat(announced)
        Result.new(verb: verb, events: announced)
      end

      def rebuild(wire)
        Event.new(name: wire["name"], aggregate: wire["aggregate"], id: wire["id"], payload: wire["payload"],
                  occurred_at: wire["occurred_at"] || @clock.call, correlation: {}).tap(&:emit!)
      end
    end
  end
end

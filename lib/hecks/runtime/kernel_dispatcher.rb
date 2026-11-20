require_relative "event"
require_relative "errors"
require_relative "caller"
require_relative "declarations"
require_relative "kernel_dispatcher/refusals"
require_relative "kernel_dispatcher/unanswered"
require_relative "kernel_dispatcher/settled"
require_relative "kernel_dispatcher/result"
require_relative "kernel_dispatcher/rebuilding"

module Hecks
  module Runtime
    # A dispatcher whose `dispatch` is one line of the kernel's host protocol (ADR 0189), sent
    # through a `RustBuild::KernelClient`. The kernel runs the command and answers the events; this
    # class rebuilds each as a `Runtime::Event`, stamps it from the clock, and keeps it in `events`.
    #
    # It answers what `Runtime::Dispatcher` answers where the protocol carries it (see {Settled}
    # for the store read back and reset), and sends the bound caller's role on each step. What
    # the protocol does not carry yet is raised as {NotAnswered} (see {Unanswered}), never
    # answered empty. A flat dispatch's refusal and a `dry_run?` refusal are raised as the Ruby
    # class the kernel names (see {Refusals} and {Rebuilding}), with the kernel's text; a refused
    # dispatch addressed with `to:` as {Refused}; a dispatch from inside a callback as
    # {NestedDispatch}.
    class KernelDispatcher
      # `Declarations` answers the described bluebooks; it comes before `Settled`, so `Settled`'s
      # `repository`, which reads the kernel's store, wins over the registry's.
      include Declarations
      include Unanswered
      include Settled
      include Rebuilding

      # Raised when the kernel refuses a dispatch; the message is the kernel's error.
      class Refused < StandardError; end

      # Raised when a dispatch starts while another is still open on the same dispatcher.
      class NestedDispatch < StandardError; end

      # @return [Array<Runtime::Event>] every event the kernel announced, oldest first
      attr_reader :events

      # @param client [RustBuild::KernelClient] a connected client
      # @param clock [#call] answers the `occurred_at` stamp for a rebuilt event
      # @param registry [Runtime::Registry, nil] the described declarations, read by `registry`
      #   and `verbs`
      def initialize(client, clock: -> { Event.stamp }, registry: nil)
        @client = client
        @clock = clock
        @registry = registry
        @events = []
        @lock = Mutex.new
      end

      # @return [Runtime::Registry] the described declarations the kernel runs
      # @raise [NotAnswered] when the dispatcher was built without one
      def registry = @registry || unanswered("registry", "no described registry was given")

      # @return [Array<String>] every verb the described bluebooks declare, sorted
      # @raise [NotAnswered] when the dispatcher was built without a registry
      def verbs = registry.verbs

      # Runs one command in the kernel, addressed as `Runtime::Dispatcher#dispatch` addresses it.
      #
      # @param verb [String] a qualified command, such as `Pizzas::Order.CreatePizza`
      # @param to [String, Hash, nil] the receiver: an identity, or an entity route; when nil the
      #   facts are sent flat, as `dispatch_flat` sends them
      # @param with [Hash, nil] the command's facts
      # @return [Result] the verb and the events it announced
      # @raise [Refused] when the kernel refuses
      # @raise [NestedDispatch] when called while another dispatch is open
      def dispatch(verb, to: nil, with: nil)
        return dispatch_flat(verb, with || {}) unless to

        step = { "verb" => verb, "to" => to, "with" => with || {} }.merge(caller_fields)
        exclusively(verb) { settle(verb, @client.call(step)) }
      end

      # @param verb [String] a qualified command
      # @param args [Hash] the command's facts, keyed by argument name
      # @return [Result] the verb and the events it announced
      # @raise [StandardError] the `Runtime::DOMAIN_REFUSALS` class the kernel names for a refusal,
      #   else {Refused}
      # @raise [NestedDispatch] when called while another dispatch is open
      def dispatch_flat(verb, args = {})
        exclusively(verb) do
          answer = @client.dispatch(verb, args, caller: caller_fields)
          raise refusal_of(verb, args, answer) unless answer["ok"]

          settle(verb, answer)
        end
      end

      # Answers whether a command would succeed now, without saving, emitting or reacting.
      #
      # @param verb [String] a qualified command
      # @param args [Hash] the facts as flat keywords; `to` and `with` are ordinary facts here
      # @return [true] whenever the kernel refuses nothing
      # @raise [StandardError] the `Runtime::DOMAIN_REFUSALS` class the kernel names, else {Refused}
      def dry_run?(verb, **args)
        answer = exclusively(verb) { @client.call({ "dry_run" => verb, "args" => args }.merge(caller_fields)) }
        raise Refusals.from_dry_run(answer) unless answer["ok"]

        true
      end

      # Finishes stalled saga legs. The kernel runs each saga leg inside the dispatch and marks
      # none stalled, and a Memory boot carries none over, so there is nothing to finish.
      #
      # @return [void]
      def redrive_sagas! = nil

      # Ends the kernel connection.
      #
      # @return [void]
      def close = @client.close

      private

      def exclusively(verb, &)
        raise NestedDispatch, "#{verb} was dispatched inside an open dispatch; not supported" if @lock.owned?

        @lock.synchronize(&)
      end

      def settle(verb, answer)
        raise Refused, answer.fetch("error") unless answer["ok"]

        announced = answer.fetch("events").map { |wire| rebuild(wire) }
        @events.concat(announced)
        Result.new(verb: verb, events: announced, store: method(:stored))
      end
    end
  end
end

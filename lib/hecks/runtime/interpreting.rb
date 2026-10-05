require_relative "value"
require_relative "aggregate_lock"
require_relative "needs"

module Hecks
  module Runtime
    # Shared by the stepwise interpreters: the traced step and coercion of declared arguments.
    module Interpreting
      # Gives each including interpreter its own `trace`, set by specs to observe dispatch order.
      # @param interpreter [Class] the class (`CommandInterpreter`, `EntityInterpreter`)
      #   including this module
      # @return [void]
      def self.included(interpreter)
        interpreter.singleton_class.attr_accessor :trace
      end

      private

      # Fills each outside fact the command `needs` and the caller left out. A value the caller
      # supplied is kept, so a test or a back-fill can name its own time.
      #
      # @param command [Class] the command being dispatched
      # @param args [Hash{Symbol => Object}] the arguments the caller passed
      # @return [Hash{Symbol => Object}] `args`, with each missing needed fact answered
      # @raise [Runtime::WiringError] when the port that answers a fact is not bound exactly once
      def enrich_arguments(command, args)
        fill_defaults(command, fill_needs(command, args))
      end

      # Answers each fact the command `needs` that the caller left out (see `Needs`).
      def fill_needs(command, args) = Needs.fill(command, args, registry: @registry)

      # Gives each argument the caller left out the default its attribute declares
      # (`attribute :runs, Count, default: 30`), so a declared default holds on every way in and
      # not only where a door spells it out. An argument the caller passed is kept, whatever it is.
      #
      # @param command [Class] the command being dispatched
      # @param args [Hash{Symbol => Object}] the arguments the caller passed
      # @return [Hash{Symbol => Object}] `args`, with each absent defaulted argument filled
      def fill_defaults(command, args)
        absent = command.attributes.reject do |attribute|
          attribute.default.nil? || args.key?(attribute.name.to_sym) || args.key?(attribute.name.to_s)
        end
        return args if absent.empty?

        args.merge(absent.to_h { |attribute| [attribute.name.to_sym, attribute.default] })
      end

      # Logged after the step's work, so trace order is completion order.
      def step(name)
        result = yield
        self.class.trace << name if self.class.trace
        result
      end

      # Runs `order` by sending each `step_<name>` handler; `save` onward shares one transaction.
      # The outbox enqueue rides on `emit`; the vocabulary's step list is a pinned contract.
      def run_dispatch_order(order, ctx)
        split = order.index(:save)
        return order.each { |name| send(:"step_#{name}", ctx) } unless split && ctx.respond_to?(:repository) && ctx.repository

        order[0...split].each { |name| send(:"step_#{name}", ctx) }
        ctx.repository.transaction do
          order[split..].each { |name| send(:"step_#{name}", ctx) }
          enqueue_outbox(ctx)
        end
      end

      # Enqueues outbox rows for the just-emitted events inside the save's transaction.
      def enqueue_outbox(ctx)
        return if ctx.dry_run || !ctx.respond_to?(:outbox_rows=)

        ctx.outbox_rows = @registry.outbox.enqueue(ctx.repository, Array(ctx.result), ctx.domain)
      end

      # Picks the isolation by capability: CAS needs none, a cross-process lock uses the
      # repository's write lock, and the rest get a striped in-process Mutex (ADR 0036).
      # A nil `lock_key_id` still locks correctly, just by aggregate type.
      def run_dispatch_order_with_isolation(order, ctx, lock_key_id:)
        capabilities = ctx.repository.capabilities
        if capabilities.include?(:optimistic_concurrency)
          run_dispatch_order(order, ctx)
        elsif capabilities.include?(:cross_process_lock)
          ctx.repository.with_write_lock { run_dispatch_order(order, ctx) }
        else
          AggregateLock.for(ctx.domain, ctx.aggregate, lock_key_id).synchronize { run_dispatch_order(order, ctx) }
        end
      end

      # Passes each declared payload attribute through the reference gate, then coercion.
      def coerce_declared_arguments(aggregate, command, args)
        command.attributes.each_with_object(args.dup) do |attribute, normalized|
          next unless normalized.key?(attribute.name)

          Value.refuse_object_reference(command, attribute, normalized[attribute.name])
          # A has_many argument mirrors the aggregate's reference list, which words its own refusal.
          reference_list = aggregate.attribute(attribute.name)&.reference?
          Value.refuse_scalar_list(command, attribute, normalized[attribute.name]) unless reference_list
          normalized[attribute.name] = Value.for_attribute(aggregate, attribute, normalized[attribute.name], argument: true)
        end
      end

      # Coercion only; the unknown/absent-argument refusals are separate dispatch steps.
      def normalize_args(aggregate, command, args)
        coerce_declared_arguments(aggregate, command, args)
      end
    end
  end
end

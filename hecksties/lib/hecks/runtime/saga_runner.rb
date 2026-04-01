# Hecks::SagaRunner
#
# Executes a saga definition step-by-step through the command bus. Tracks
# state as: pending -> running -> completed | compensating -> failed.
# On step failure, reverses through completed steps dispatching each
# compensation command (best-effort).
#
#   runner = SagaRunner.new(saga_def, command_bus, saga_store, event_bus)
#   result = runner.start(order_id: "123")
#   result[:state]  # => :completed
#
module Hecks
  class SagaRunner
    # @return [Hecks::DomainModel::Behavior::Saga] the saga definition
    attr_reader :saga

    # Creates a new runner for the given saga definition.
    #
    # @param saga [Hecks::DomainModel::Behavior::Saga] the saga IR
    # @param command_bus [Hecks::Commands::CommandBus] for dispatching commands
    # @param store [Hecks::SagaStore] for persisting saga state
    # @param event_bus [Hecks::EventBus] for publishing saga lifecycle events
    def initialize(saga, command_bus, store, event_bus)
      @saga = saga
      @command_bus = command_bus
      @store = store
      @event_bus = event_bus
    end

    # Start a new saga instance with the given attributes.
    #
    # @param attrs [Hash] keyword arguments passed to each step command
    # @return [Hash] saga instance state with :saga_id, :state, :completed_steps, :error
    def start(**attrs)
      saga_id = generate_id
      instance = new_instance(saga_id, attrs)
      @store.save(saga_id, instance)
      execute(instance)
    end

    private

    def generate_id
      "saga_#{SecureRandom.hex(8)}"
    end

    def new_instance(saga_id, attrs)
      {
        saga_id: saga_id,
        saga_name: @saga.name,
        state: :pending,
        attrs: attrs,
        completed_steps: [],
        error: nil
      }
    end

    def execute(instance)
      instance[:state] = :running
      @store.save(instance[:saga_id], instance)

      @saga.steps.each_with_index do |step, idx|
        result = execute_step(step, instance)
        if result[:success]
          instance[:completed_steps] << idx
        else
          instance[:error] = result[:error]
          compensate(instance)
          return instance
        end
      end

      instance[:state] = :completed
      @store.save(instance[:saga_id], instance)
      instance
    end

    def execute_step(step, instance)
      @command_bus.dispatch(step.command, **instance[:attrs])
      { success: true }
    rescue => e
      { success: false, error: "#{step.command}: #{e.message}" }
    end

    def compensate(instance)
      instance[:state] = :compensating
      @store.save(instance[:saga_id], instance)

      instance[:completed_steps].reverse_each do |idx|
        step = @saga.steps[idx]
        next unless step.compensatable?
        begin
          @command_bus.dispatch(step.compensate, **instance[:attrs])
        rescue => e
          # Best-effort: log and continue compensating remaining steps
          instance[:error] = "#{instance[:error]}; compensation #{step.compensate}: #{e.message}"
        end
      end

      instance[:state] = :failed
      @store.save(instance[:saga_id], instance)
    end
  end
end

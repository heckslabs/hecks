# Hecks::EventSourcing::OutboxStep
#
# Lifecycle step that stores emitted events in an outbox instead of
# publishing them directly on the event bus. The OutboxPoller later
# reads pending entries and publishes them, ensuring at-least-once
# delivery even if the process crashes between persist and publish.
#
# == Usage
#
#   # Replace EmitStep in the pipeline:
#   pipeline = [..., PersistStep, OutboxStep.new(outbox), RecordStep]
#
class Hecks::EventSourcing::OutboxStep
  # @param outbox [Hecks::EventSourcing::Outbox] the outbox to write to
  def initialize(outbox)
    @outbox = outbox
  end

  # Store emitted events in the outbox.
  #
  # @param cmd [Object] the command instance
  # @return [Object] the command instance
  def call(cmd)
    events = cmd.send(:build_events)
    cmd.instance_variable_set(:@events, events)
    cmd.instance_variable_set(:@event, events.first)
    events.each { |evt| @outbox.store(evt) }
    cmd
  end
end

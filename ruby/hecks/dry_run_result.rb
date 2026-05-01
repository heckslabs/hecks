# = Hecks::DryRunResult
#
# Value object returned by +Runtime#dry_run+. Contains the aggregate
# and event that WOULD result from executing a command, plus the
# reactive chain of policies that WOULD fire — without any side effects.
#
#   result = app.dry_run("CreatePizza", name: "Margherita")
#   result.valid?             # => true
#   result.aggregate.name     # => "Margherita"
#   result.event              # => #<CreatedPizza ...>
#   result.reactive_chain     # => [{type: :policy, ...}]
#   result.triggers_policies? # => true
#
module Hecks
  # Hecks::DryRunResult
  #
  # Value object returned by Runtime#dry_run containing the would-be aggregate, event, and reactive chain.
  #
  class DryRunResult
    attr_reader :command, :aggregate, :event, :reactive_chain

    def initialize(command:, aggregate:, event:, reactive_chain: [])
      @command = command
      @aggregate = aggregate
      @event = event
      @reactive_chain = reactive_chain
    end

    def valid?
      true
    end

    def triggers_policies?
      reactive_chain.any? { |s| s[:type] == :policy }
    end

    def inspect
      cmd = Hecks::Utils.const_short_name(command)
      evt = Hecks::Utils.const_short_name(event)
      policies = reactive_chain.select { |s| s[:type] == :policy }.map { |s| s[:policy] }
      "#<DryRunResult command=#{cmd} event=#{evt} policies=#{policies}>"
    end
  end
end

module Hecks::Features

  # Hecks::Features::SliceStep
  #
  # Value object representing a single step in a reactive flow chain.
  # Replaces plain hashes like `{ type: :command, command:, aggregate:, event: }`
  # with a proper struct that provides named accessors and hash-style [] access.
  #
  # Three step types exist:
  # - :command -- a command execution with command name, aggregate, and emitted event
  # - :policy  -- a reactive policy trigger with policy name, source event, and target command
  # - :cycle   -- marks a cycle back to a previously visited command
  #
  #   step = SliceStep.new(type: :command, command: "IssueLoan", aggregate: "Loan", event: "IssuedLoan")
  #   step.type      # => :command
  #   step.command   # => "IssueLoan"
  #   step[:aggregate] # => "Loan" (hash-style access also works)
  #
  SliceStep = Struct.new(:type, :command, :aggregate, :event, :policy, keyword_init: true)
end

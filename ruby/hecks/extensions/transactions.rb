# HecksTransactions
#
# Command bus middleware that wraps command execution in a database
# transaction when a SQL adapter is present. Inspects the command's
# associated repository to check if it has a Sequel +db+ handle. If so,
# wraps the next handler in +db.transaction { }+ for atomic execution
# with automatic rollback on error. Falls through transparently for
# memory adapters or any repository without a +db+ method.
#
# This extension is safe to load unconditionally -- it only activates
# transactional behavior when a SQL-backed repository is detected.
#
# Future gem: hecks_transactions
#
#   require "hecks_transactions"
#   # Automatically registered -- all commands through SQL repos
#   # will execute inside a database transaction.
#
require "hecks"

Hecks.describe_extension(:transactions,
  description: "Transactional command execution with rollback",
  adapter_type: :driven,
  config: {},
  wires_to: :command_bus)

Hecks.register_extension(:transactions) do |domain_mod, domain, runtime|
  # Register command bus middleware that wraps execution in a DB transaction.
  #
  # For each command dispatched:
  # 1. Checks if the command class responds to +.repository+ (generated
  #    command classes track their associated repository)
  # 2. If the repository responds to +.db+ (Sequel repositories do), wraps
  #    next_handler.call in +db.transaction { }+ for atomic execution
  # 3. If no SQL database is detected, calls next_handler directly without
  #    any transactional wrapping
  #
  # @param command [Object] the command being dispatched; its class may
  #   respond to +.repository+ to indicate the associated repository
  # @param next_handler [#call] the next handler in the middleware chain
  # @return [Object] the return value of +next_handler.call+
  runtime.use :transactions do |command, next_handler|
    repo = command.class.respond_to?(:repository) ? command.class.repository : nil
    db = repo.respond_to?(:db) ? repo.db : nil
    if db && db.respond_to?(:transaction)
      db.transaction { next_handler.call }
    else
      next_handler.call
    end
  end
end

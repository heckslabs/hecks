# HecksLogging
#
# Structured logging extension for the Hecks command bus. Logs every
# command dispatch to +$stdout+ with the command name, execution duration
# in milliseconds, and optional actor and tenant context. Uses
# +Process::CLOCK_MONOTONIC+ for accurate timing.
#
# Output format:
#   [hecks] CreatePizza 0.3ms actor=admin tenant=acme
#
# Usage:
#   require "hecks_logging"
#   app = Hecks.load(domain)
#   Pizza.create(name: "Margherita")
#   # => [hecks] CreatePizza 0.3ms actor=admin tenant=acme
#
Hecks.describe_extension(:logging,
  description: "Command execution logging",
  config: {},
  wires_to: :command_bus)

Hecks.register_extension(:logging) do |_domain_mod, _domain, runtime|
  # Register command bus middleware that logs each command execution.
  #
  # For each command dispatched:
  # 1. Extracts the unqualified command class name (last segment after "::")
  # 2. Reads the current actor role from Hecks.actor (if set and responds to #role)
  # 3. Reads the current tenant from Hecks.tenant (if set)
  # 4. Records the start time using monotonic clock
  # 5. Calls next_handler to execute the command
  # 6. Computes elapsed time in milliseconds (rounded to 1 decimal)
  # 7. Prints a structured log line to $stdout
  #
  # @param command [Object] the command being dispatched
  # @param next_handler [#call] the next handler in the middleware chain
  # @return [Object] the return value of +next_handler.call+
  runtime.use :logging do |command, next_handler|
    cmd_name = Hecks::Utils.const_short_name(command)
    actor = Hecks.actor&.respond_to?(:role) ? Hecks.actor.role : nil
    tenant = Hecks.tenant
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = next_handler.call
    duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)
    parts = ["[hecks]", cmd_name, "#{duration}ms"]
    parts << "actor=#{actor}" if actor
    parts << "tenant=#{tenant}" if tenant
    $stdout.puts parts.join(" ")
    result
  end
end

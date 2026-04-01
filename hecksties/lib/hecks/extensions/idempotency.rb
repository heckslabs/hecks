# HecksIdempotency
#
# Idempotency extension for the Hecks command bus. Deduplicates retried
# commands by fingerprinting the command class name and its instance
# variable values. If the same fingerprint is seen within a configurable
# TTL window, the cached result is returned instead of re-executing the
# command. Expired cache entries are cleaned on each dispatch.
#
# Configuration via environment variable:
#   HECKS_IDEMPOTENCY_TTL -- cache TTL in seconds (default: 300)
#
# Usage:
#   require "hecks_idempotency"
#   app.run("CreatePizza", name: "Margherita")  # first call executes
#   app.run("CreatePizza", name: "Margherita")  # second call returns cached
#
Hecks.describe_extension(:idempotency,
  description: "Idempotent command execution via dedup keys",
  adapter_type: :driven,
  config: {},
  wires_to: :command_bus)

Hecks.register_extension(:idempotency) do |_domain_mod, _domain, runtime|
  cache = {}
  ttl = ENV.fetch("HECKS_IDEMPOTENCY_TTL", "300").to_i

  # Register command bus middleware that deduplicates commands.
  #
  # For each command dispatched:
  # 1. Computes a fingerprint from the command class name and all instance
  #    variable name/value pairs (sorted for deterministic hashing)
  # 2. Cleans expired entries from the cache (older than TTL seconds)
  # 3. If the fingerprint exists in the cache, returns the cached result
  # 4. Otherwise, executes the command, caches the result with a timestamp,
  #    and returns the result
  #
  # @param command [Object] the command being dispatched
  # @param next_handler [#call] the next handler in the middleware chain
  # @return [Object] the command result (cached or freshly computed)
  runtime.use :idempotency do |command, next_handler|
    attrs = command.instance_variables.sort.map { |v| [v, command.instance_variable_get(v)] }
    fingerprint = [command.class.name, attrs].hash
    now = Time.now.to_f

    # Clean expired entries
    cache.reject! { |_, v| v[:at] < now - ttl }

    if cache[fingerprint]
      cache[fingerprint][:result]
    else
      result = next_handler.call
      cache[fingerprint] = { result: result, at: now }
      result
    end
  end
end

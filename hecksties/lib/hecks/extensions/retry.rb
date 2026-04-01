# HecksRetry
#
# Command bus middleware that auto-retries failed commands with exponential
# backoff. Only retries on transient errors (network, timeout, and other
# non-domain StandardError subclasses). Domain errors (Hecks::Error
# subclasses like ValidationError, GuardRejected) are never retried and
# propagate immediately.
#
# The backoff formula is: base_delay * 2^(attempt - 1)
# For example, with base_delay=0.1: 0.1s, 0.2s, 0.4s, ...
#
# Configuration via environment variables:
#   HECKS_RETRY_MAX   -- maximum retry attempts (default: 3)
#   HECKS_RETRY_DELAY -- base delay in seconds (default: 0.1)
#
# Future gem: hecks_retry
#
#   require "hecks_retry"
#   # Automatically registered -- transient failures will be retried
#   # up to HECKS_RETRY_MAX times with exponential backoff.
#
require "hecks"

Hecks.describe_extension(:retry,
  description: "Automatic command retry with backoff",
  adapter_type: :driven,
  config: { max_attempts: { default: 3, desc: "Max retry attempts" } },
  wires_to: :command_bus)

Hecks.register_extension(:retry) do |domain_mod, domain, runtime|
  max_retries = ENV.fetch("HECKS_RETRY_MAX", "3").to_i
  base_delay = ENV.fetch("HECKS_RETRY_DELAY", "0.1").to_f

  # Register command bus middleware that retries transient failures.
  #
  # For each command dispatched:
  # 1. Attempts to call next_handler
  # 2. If a Hecks::Error (domain error) is raised, re-raises immediately
  #    without retrying -- domain errors are intentional rejections
  # 3. If any other StandardError is raised and attempts < max_retries,
  #    sleeps for an exponentially increasing duration and retries
  # 4. If max_retries is exceeded, the final error propagates to the caller
  #
  # @param command [Object] the command being dispatched
  # @param next_handler [#call] the next handler in the middleware chain
  # @return [Object] the return value of +next_handler.call+
  # @raise [Hecks::Error] domain errors are always re-raised immediately
  # @raise [StandardError] transient errors are re-raised after max retries
  runtime.use :retry do |command, next_handler|
    attempts = 0
    begin
      attempts += 1
      next_handler.call
    rescue Hecks::Error
      raise  # domain errors are not retried
    rescue StandardError => e
      if attempts < max_retries
        sleep(base_delay * (2 ** (attempts - 1)))
        retry
      end
      raise
    end
  end
end

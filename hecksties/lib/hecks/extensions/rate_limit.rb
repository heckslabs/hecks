# HecksRateLimit
#
# Rate limiting extension for the Hecks command bus. Uses a sliding window
# counter per actor to limit how many commands an actor can dispatch in
# a configurable time period. Only applies when +Hecks.actor+ is set;
# commands without an actor bypass rate limiting entirely.
#
# The sliding window works by storing timestamps of each command dispatch
# per actor+command key. On each dispatch, expired timestamps (older than
# the period) are pruned, and if the remaining count meets or exceeds the
# limit, a +Hecks::RateLimitExceeded+ error is raised.
#
# Configuration via environment variables:
#   HECKS_RATE_LIMIT  -- max commands per window (default: 60)
#   HECKS_RATE_PERIOD -- window size in seconds (default: 60)
#
# Usage:
#   require "hecks_rate_limit"
#   Hecks.actor = current_user
#   app.run("CreatePizza", name: "Margherita")  # rate-limited per actor
#
Hecks.describe_extension(:rate_limit,
  description: "Per-actor sliding window rate limiting",
  adapter_type: :driven,
  config: {},
  wires_to: :command_bus)

Hecks.register_extension(:rate_limit) do |_domain_mod, _domain, runtime|
  window = {}
  limit = ENV.fetch("HECKS_RATE_LIMIT", "60").to_i
  period = ENV.fetch("HECKS_RATE_PERIOD", "60").to_i

  # Register command bus middleware that enforces per-actor rate limits.
  #
  # For each command dispatched:
  # 1. Checks if Hecks.actor is set; if not, skips rate limiting
  # 2. Builds a composite key from the actor's ID (or string representation)
  #    and the command's fully-qualified class name
  # 3. Prunes timestamps older than the configured period from the window
  # 4. If the number of remaining timestamps >= limit, raises
  #    Hecks::RateLimitExceeded with a descriptive message
  # 5. Otherwise, records the current timestamp and calls next_handler
  #
  # @param command [Object] the command being dispatched
  # @param next_handler [#call] the next handler in the middleware chain
  # @return [Object] the return value of +next_handler.call+
  # @raise [Hecks::RateLimitExceeded] when the actor exceeds the rate limit
  runtime.use :rate_limit do |command, next_handler|
    actor = Hecks.actor
    if actor
      key = "#{actor.respond_to?(:id) ? actor.id : actor}:#{command.class.name}"
      now = Time.now.to_f
      window[key] ||= []
      window[key].reject! { |t| t < now - period }
      if window[key].size >= limit
        raise Hecks::RateLimitExceeded, "Rate limit exceeded (#{limit}/#{period}s)"
      end
      window[key] << now
    end
    next_handler.call
  end
end

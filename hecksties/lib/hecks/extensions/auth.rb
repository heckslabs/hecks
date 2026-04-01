# HecksAuth
#
# Authentication and authorization extension for Hecks domains. Reads
# actor metadata from the DSL and registers command bus middleware that
# enforces access control. Commands without actors are always allowed;
# commands with actor declarations require a matching role on the current
# +Hecks.actor+.
#
# The extension builds a lookup table mapping fully-qualified command class
# names to their required actor roles (from the DSL). On each command
# dispatch, the middleware checks whether the current actor's role is in
# the allowed list. Raises +Hecks::Unauthenticated+ if no actor is set,
# or +Hecks::Unauthorized+ if the actor's role is not permitted.
#
# Future gem: hecks_auth
#
#   # Gemfile
#   gem "cats_domain"
#   gem "hecks_auth"
#
#   # Set the current actor (any object responding to #role)
#   Hecks.actor = OpenStruct.new(role: "Admin")
#   Cat.adopt(name: "Whiskers")  # checks actor role against DSL
#
Hecks.describe_extension(:auth,
  description: "Actor-based authorization via port guards",
  config: {},
  wires_to: :command_bus)

Hecks.register_extension(:auth) do |domain_mod, domain, runtime|
  # Build a lookup of command class name → required actor roles.
  #
  # Iterates all aggregates and their commands, collecting any that have
  # actor declarations. The key is the fully-qualified Ruby class name
  # (e.g. "CatsDomain::Cat::Commands::Adopt"), and the value is an Array
  # of role name strings (e.g. ["Admin", "Vet"]).
  actor_map = {}
  domain.aggregates.each do |agg|
    agg.commands.each do |cmd|
      next if cmd.actors.empty?
      fqn = "#{domain_mod.name}::#{agg.name}::Commands::#{cmd.name}"
      actor_map[fqn] = cmd.actors.map(&:name)
    end
  end

  next if actor_map.empty?

  # Register command bus middleware that enforces actor-based authorization.
  #
  # For each command dispatched:
  # 1. Looks up the command's fully-qualified name in actor_map
  # 2. If no entry exists, the command has no actor requirements -- allow it
  # 3. If an entry exists, checks Hecks.actor is set (raises Unauthenticated if not)
  # 4. Checks actor's role is in the required roles list (raises Unauthorized if not)
  # 5. Calls next_handler to continue the middleware chain
  runtime.use :auth do |command, next_handler|
    fqn = command.class.name
    required_roles = actor_map[fqn]

    if required_roles
      actor = Hecks.actor
      raise Hecks::Unauthenticated, "No actor set. Call Hecks.actor = user before running #{Hecks::Utils.const_short_name(command)}" unless actor
      role = actor.respond_to?(:role) ? actor.role.to_s : actor.to_s
      unless required_roles.include?(role)
        raise Hecks::Unauthorized, "Actor '#{role}' is not authorized for #{Hecks::Utils.const_short_name(command)}. Required: #{required_roles.join(', ')}"
      end
    end

    next_handler.call
  end
end

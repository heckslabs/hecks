# HecksAudit
#
# Audit trail extension that records an immutable log entry for every
# domain event published on the event bus. Captures the event class name,
# full attribute data, and timestamp. Optionally pairs with command bus
# middleware to enrich entries with command name, actor, and tenant.
#
# Usage:
#   require "hecks_audit"
#
#   app = Hecks.load(domain)
#   audit = HecksAudit.new(app.event_bus)
#
#   # Optional: add command context via middleware
#   app.use(:audit) { |cmd, nxt| audit.around_command(cmd, nxt) }
#
#   Pizza.create(name: "Margherita")
#   audit.log.last[:event_name]  # => "CreatedPizza"
#   audit.log.last[:event_data]  # => { name: "Margherita" }
#
class HecksAudit
  # @return [Array<Hash>] the immutable audit log; each entry is a Hash with
  #   keys :command, :actor, :tenant, :timestamp, :event_name, :event_data
  attr_reader :log

  # Subscribe to all events on the given bus and begin recording.
  #
  # Registers an +on_any+ listener that calls {#record} for every domain
  # event published. The log starts empty.
  #
  # @param event_bus [Hecks::EventBus] the event bus to subscribe to;
  #   must respond to +on_any+ accepting a block that receives an event
  # @return [HecksAudit] a new audit instance already listening
  def initialize(event_bus)
    @log = []
    @pending_context = nil
    event_bus.on_any { |event| record(event) }
  end

  # Command bus middleware: sets command context for the next audit entry.
  #
  # Stores the command name, actor, and tenant so the next event recorded
  # via {#record} includes this context. After the event is recorded the
  # pending context is cleared, ensuring it only applies to the immediate
  # command execution.
  #
  # @example Wiring as middleware
  #   app.use(:audit) { |cmd, nxt| audit.around_command(cmd, nxt) }
  #
  # @param command [Object] the command being dispatched; its class name
  #   (last segment after "::") is stored as the command identifier
  # @param next_handler [#call] the next handler in the middleware chain;
  #   called after storing context
  # @param actor [String, nil] optional actor identifier (e.g. a user role)
  # @param tenant [String, nil] optional tenant identifier
  # @return [Object] the return value of +next_handler.call+
  def around_command(command, next_handler, actor: nil, tenant: nil)
    @pending_context = {
      command: Hecks::Utils.const_short_name(command),
      actor: actor,
      tenant: tenant
    }
    next_handler.call
  end

  # Clear the audit log.
  #
  # Removes all recorded entries. Useful in tests or when rotating logs.
  #
  # @return [Array] the now-empty log array
  def clear
    @log.clear
  end

  private

  # Record a single domain event into the audit log.
  #
  # Builds an entry hash from the event and any pending command context,
  # then clears the pending context. Each entry contains:
  # - +:command+ - the command name (or nil if no context was set)
  # - +:actor+ - the actor identifier (or nil)
  # - +:tenant+ - the tenant identifier (or nil)
  # - +:timestamp+ - Time.now when the event was recorded
  # - +:event_name+ - the unqualified class name of the event
  # - +:event_data+ - a Hash of the event's attributes extracted via {#extract_attrs}
  #
  # @param event [Object] the domain event; its class name and initialize
  #   parameters are inspected to extract attribute data
  # @return [void]
  def record(event)
    entry = {
      command: @pending_context&.dig(:command),
      actor: @pending_context&.dig(:actor),
      tenant: @pending_context&.dig(:tenant),
      timestamp: Time.now,
      event_name: Hecks::Utils.const_short_name(event),
      event_data: extract_attrs(event)
    }
    @pending_context = nil
    @log << entry
  end

  # Extract attribute values from a domain event by inspecting its
  # initialize parameters.
  #
  # Reflects on the event class's +initialize+ method to find parameter
  # names, then reads each value via +send+. Returns an empty Hash if
  # reflection fails (e.g. for events with unusual constructors).
  #
  # @param event [Object] the domain event to extract attributes from
  # @return [Hash{Symbol => Object}] attribute name to value mapping
  def extract_attrs(event)
    params = event.class.instance_method(:initialize).parameters
    params.each_with_object({}) do |(_, name), h|
      next unless name
      h[name] = event.send(name) if event.respond_to?(name)
    end
  rescue
    {}
  end
end

# Auto-wire when loaded: subscribe to shared event bus and add middleware.
Hecks.describe_extension(:audit,
  description: "Immutable audit trail for every domain event",
  config: {},
  wires_to: :event_bus)

Hecks.register_extension(:audit) do |_domain_mod, _domain, runtime|
  bus = Hecks.event_bus || runtime.event_bus
  audit = HecksAudit.new(bus)
  Hecks.instance_variable_set(:@_audit, audit)
  Hecks.define_singleton_method(:audit_log) { @_audit.log }
  runtime.use(:audit) do |cmd, nxt|
    audit.around_command(cmd, nxt, actor: Hecks.actor&.respond_to?(:role) ? Hecks.actor.role : nil)
  end
end

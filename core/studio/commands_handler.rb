# CommandsHandler
#
# POST /commands dispatch logic for the Hecks Studio. Parses the
# JSON body, dispatches into the runtime, captures emitted events
# via runtime.event_bus.on_any, optionally records the dispatch as
# a CommandInvocation audit row (best-effort), and returns a
# canonical JSON response shape.
#
# Extracted from app.rb so the route handler stays a one-liner and
# both pieces stay under the project's 200-LOC ceiling.
#
# Request body :
#   { "aggregate": "TickedFeature",
#     "command":   "Tick",
#     "attrs":     { "last_tick_at": "2026-05-01T20:00:00Z" } }
#
# Success response (HTTP 200) :
#   { "ok": true,
#     "aggregate": "TickedFeature",
#     "command":   "Tick",
#     "events":    ["Ticked", "StatuslineUpdated"] }
#
# Error response (HTTP 422) :
#   { "ok": false,
#     "error": "<message>" }
#
# Usage :
#   result = CommandsHandler.call(runtime, request_body_json)
#   status result.fetch(:status)
#   json   result.fetch(:body)
#

require "json"
require "time"

module CommandsHandler
  AUDIT_AGGREGATE = "CommandInvocation".freeze
  AUDIT_COMMAND   = "RecordCommandInvocation".freeze

  module_function

  # Dispatch one command and return the response shape.
  #
  # @param runtime [Hecks::Runtime] the booted studio runtime
  # @param raw_body [String] the request body — must be JSON
  # @return [Hash] { status: Integer, body: Hash }
  def call(runtime, raw_body)
    payload = parse(raw_body)
    return reject(422, "request body must be a JSON object") unless payload.is_a?(Hash)

    aggregate = string(payload, "aggregate")
    command   = string(payload, "command")
    attrs     = payload["attrs"] || payload[:attrs] || {}

    return reject(422, "missing aggregate") if aggregate.empty?
    return reject(422, "missing command")   if command.empty?
    return reject(422, "attrs must be a JSON object") unless attrs.is_a?(Hash)

    dispatch(runtime, aggregate, command, attrs)
  rescue StandardError => e
    reject(422, "#{e.class}: #{e.message}")
  end

  # Run the dispatch through the runtime, capturing emitted events
  # via a one-shot global subscription. The subscription is added
  # before dispatch and left in place — runtime.event_bus has no
  # unsubscribe — but the captured array is local, so listeners
  # accumulate but the response is correct per call.
  #
  # Role : the studio binds 127.0.0.1 only, so anyone reaching
  # /commands has full authority. We honour the command's declared
  # role by setting Hecks.current_role to the first declared role
  # before dispatching ; this lets role-gated commands (Tick is
  # "Daemon", MarkLate is "System") run from the dashboard.
  def dispatch(runtime, aggregate, command, attrs)
    captured = []
    runtime.event_bus.on_any { |evt| captured << event_short_name(evt) }

    command_def = find_command(runtime, command)
    safe_attrs  = filter_known_attrs_for(command_def, attrs)

    with_role(command_def) { runtime.run(command, **safe_attrs) }

    # Snapshot what landed during dispatch ; audit recording fires
    # its own Recorded event which we deliberately exclude.
    user_events = captured.dup
    record_audit(runtime, aggregate, command, attrs, user_events)
    {
      status: 200,
      body: { ok: true, aggregate: aggregate, command: command, events: user_events }
    }
  rescue StandardError => e
    { status: 422, body: { ok: false, error: "#{e.class}: #{e.message}" } }
  end

  # Set Hecks.current_role for the duration of the block. Restores
  # whatever was set before — important when /commands is hit
  # concurrently and one dispatch must not leak its role into the
  # next thread's actor wiring.
  def with_role(command_def)
    role = role_for(command_def)
    if role && defined?(Hecks) && Hecks.respond_to?(:current_role=)
      previous = Hecks.current_role
      Hecks.current_role = role
      begin
        yield
      ensure
        Hecks.current_role = previous
      end
    else
      yield
    end
  end

  # First declared role on the command, or nil. Bluebook role names
  # (e.g., "Daemon", "System") are downcased by the runtime check.
  def role_for(command_def)
    return nil unless command_def
    actors = command_def.respond_to?(:actors) ? command_def.actors : nil
    return nil if actors.nil? || actors.empty?
    first = actors.first
    first.respond_to?(:name) ? first.name : first.to_s
  end

  # Drop attrs the resolved command does not declare (and treat
  # nil/empty values as absent). Lets the harness POST a form's
  # full attribute set without each command needing to declare
  # every column.
  def filter_known_attrs_for(command_def, attrs)
    return symbolize(attrs) unless command_def

    known = (command_def.attributes.map(&:name).map(&:to_s) +
             (command_def.references || []).map { |r| r.name.to_s }).to_set

    attrs.each_with_object({}) do |(k, v), h|
      key = k.to_s
      next unless known.include?(key)
      next if v.nil? || (v.is_a?(String) && v.empty?)
      h[key.to_sym] = v
    end
  end

  # Walk the domain IR for a command by name.
  def find_command(runtime, command_name)
    runtime.domain.aggregates.each do |agg|
      cmd = agg.commands.find { |c| c.name == command_name.to_s }
      return cmd if cmd
    end
    nil
  end

  # Best-effort audit-row recording. Never raises — if the audit
  # path fails (CRUD didn't generate the command, JSON encoding
  # blew up, etc.) the user-facing dispatch still returns 200.
  def record_audit(runtime, aggregate, command, attrs, events)
    runtime.run(
      "CreateCommandInvocation",
      aggregate_name:      aggregate,
      command:             command,
      attrs_json:          safe_json(attrs),
      result:              "ok",
      emitted_event_names: events,
      dispatched_at:       Time.now.utc.iso8601
    )
  rescue StandardError
    # Audit recording is best-effort — never break dispatch.
    nil
  end

  # ------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------

  def parse(raw_body)
    return {} if raw_body.nil? || raw_body.empty?
    JSON.parse(raw_body)
  rescue JSON::ParserError
    nil
  end

  def reject(status, message)
    { status: status, body: { ok: false, error: message } }
  end

  def string(hash, key)
    (hash[key] || hash[key.to_sym] || "").to_s.strip
  end

  def symbolize(hash)
    hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
  end

  def event_short_name(evt)
    klass = evt.respond_to?(:class) ? evt.class.name.to_s : ""
    klass.split("::").last || klass
  end

  def safe_json(value)
    JSON.generate(value)
  rescue StandardError
    value.inspect
  end
end

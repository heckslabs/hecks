require_relative "ir_relationship_core"

# A closed, inspectable subset of event-triggered relationships. The compiler reads
# policy and saga IR; the runner interprets those declarations after each commit.
module RelationshipReactions
  module_function

  MAX_DEPTH = 5

  def declarations(runtime)
    runtime.bluebooks.flat_map do |domain, bluebook|
      bluebook.policies.map { |policy| [domain, policy.to_h] }
    end
  end

  def saga_declarations(runtime)
    runtime.bluebooks.flat_map do |domain, bluebook|
      bluebook.sagas.map { |saga| [domain, saga.to_h] }
    end
  end

  def matches?(on, event)
    parts = on.split(".")
    parts.length == 1 ? event.fetch("name") == on :
      event.fetch("name") == parts.last && event.fetch("aggregate").split("::").last == parts.first
  end

  def identity_heads(runtime, event)
    domain, aggregate_name = event.fetch("aggregate").split("::", 2)
    aggregate = runtime.bluebooks.fetch(domain).aggregate(aggregate_name)
    aggregate.to_h.fetch(:identified_by).map { |path| path.split(".").first }
  end

  def scoped_value(source, event, extra = {}, heads = [])
    return source unless source.is_a?(String)
    if (literal = /\A\{([a-z_]+):\s*(?:"([^"]*)"|(-?\d+))\}\z/.match(source))
      return { literal[1] => literal[2] || literal[3].to_i }
    end
    return source[1..-2] if source.start_with?('"') && source.end_with?('"')
    return source unless source.start_with?(":")
    name = source.delete_prefix(":")
    return extra.fetch(name) if extra.key?(name)
    return event.fetch("payload")[name] if event.fetch("payload").key?(name)
    return event.fetch("id") if name == "id"
    return event.fetch("id") if heads.include?(name)
    raise "unbound reaction source #{source}"
  end

  def bind(mapping, event, extra = {}, heads = [])
    return IRRelationship.copy(event.fetch("payload")) if mapping.empty?
    mapping.to_h { |name, source| [name, IRRelationship.copy(scoped_value(source, event, extra, heads))] }
  end

  def coerce_args(aggregate, command_name, args)
    types = aggregate.command(command_name).to_h.fetch(:attributes).to_h do |attribute|
      [attribute.fetch(:name).to_s, attribute.fetch(:type)]
    end
    args.transform_keys(&:to_s).tap do |result|
      result.each do |name, value|
        type = types[name]
        vo = type && aggregate.value_object(type)
        if value.is_a?(Hash)
          if vo
            vo.to_h.fetch(:attributes).each do |field|
              field_name = field.fetch(:name).to_s
              value[field_name] = IRRelationship.copy(field[:default]) if !value.key?(field_name) && !field[:default].nil?
            end
          end
          next
        end
        next unless vo && vo.to_h.fetch(:attributes).length == 1
        sole = vo.to_h.fetch(:attributes).first.fetch(:name).to_s
        result[name] = { sole => value }
      end
    end
  end

  def dispatch(runtime, world, domain, target, args, depth, cache, saga_state, explicit: false, correlation: nil)
    aggregate_name, command_name = target.split(".", 2)
    bluebook = runtime.bluebooks[domain]
    return { delivered: false, reason: "unknown domain #{domain}" } unless bluebook
    aggregate = bluebook.aggregate(aggregate_name)
    return { delivered: false, reason: "unknown command #{target}" } unless aggregate && aggregate.command(command_name)
    args = coerce_args(aggregate, command_name, args)
    declared = aggregate.command(command_name).to_h.fetch(:attributes).map { |a| a.fetch(:name).to_s }
    payload_args = explicit ? args.slice(*declared) : IRRelationship.copy(args)
    if explicit
      receiver_keys = aggregate.to_h.fetch(:identified_by).map { |path| path.split(".").first }
      receiver_keys << aggregate.name.gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase
      args = args.slice(*(declared + receiver_keys))
    end
    program = cache[[domain, target]] ||= IRRelationship.compile(aggregate, command_name)
    event_start = world.fetch("events").length
    refusal_start = world.fetch("refusals").length
    IRRelationship.run(program, world, aggregate, command_name, args, domain, event_payload: payload_args, runtime: runtime)
    if world.fetch("refusals").length > refusal_start
      reason = world.fetch("refusals").last.fetch("error")
      world.fetch("refusals").slice!(refusal_start..)
      return { delivered: false, reason: reason }
    end
    react(runtime, world, world.fetch("events")[event_start..], depth, cache, saga_state, correlation: correlation)
    { delivered: true }
  end

  def saga_handler(saga, event_name, state)
    saga.fetch(:handlers).find { |h| h.fetch(:event_type) == event_name && h.fetch(:from_state) == state }
  end

  def saga_transition(runtime, world, home, saga, event, id, instance, event_name, depth, cache, saga_state)
    handlers = saga.fetch(:handlers).select { |h| h.fetch(:event_type) == event_name }
    return if handlers.empty?
    base = { "process_manager" => saga.fetch(:name), "on" => event_name, "instance" => id }
    handler = saga_handler(saga, event_name, instance.fetch(:state))
    unless handler
      expected = handlers.map { |h| h.fetch(:from_state).inspect }.uniq.join(" or ")
      world.fetch("sagas") << base.merge("advanced" => false,
                                          "reason" => "in #{instance.fetch(:state).inspect}, not #{expected}")
      return
    end
    previous = instance.fetch(:state)
    instance[:state] = handler.fetch(:to_state)
    world.fetch("sagas") << base.merge("advanced" => true, "from" => previous, "to" => instance.fetch(:state))
    if event_name == "refused"
      until instance.fetch(:compensations).empty?
        compensation = instance.fetch(:compensations).pop
        deliver_saga_action(runtime, world, home, saga, event, id, instance, compensation,
                            depth, cache, saga_state, compensation: true)
      end
    end
    handler.fetch(:dispatches).each do |action|
      deliver_saga_action(runtime, world, home, saga, event, id, instance, action,
                          depth, cache, saga_state)
    end
  end

  def deliver_saga_action(runtime, world, home, saga, event, id, instance, action,
                          depth, cache, saga_state, compensation: false)
    record = { "process_manager" => saga.fetch(:name), "instance" => id,
               "dispatch" => action.fetch(:command_name) }
    correlation_head = saga.fetch(:correlates_by).split(".").first
    binding_event = event.merge("payload" => instance.fetch(:memory).merge(event.fetch("payload")))
    args = action[:resolved_args] || bind(action.fetch(:with_spec), binding_event,
                                          { correlation_head => id }, identity_heads(runtime, event))
    if depth >= MAX_DEPTH
      outcome = { delivered: false, reason: "reaction depth #{MAX_DEPTH} reached" }
    else
      if !compensation && action[:compensates]
        derived = action.fetch(:compensates).merge(resolved_args: bind(action.fetch(:compensates).fetch(:with_spec),
          binding_event, { correlation_head => id }, identity_heads(runtime, event)))
        instance.fetch(:compensations) << derived
      end
      outcome = dispatch(runtime, world, home, action.fetch(:command_name), args,
                         depth + 1, cache, saga_state, explicit: true, correlation: id)
    end
    unless outcome.fetch(:delivered)
      instance.fetch(:compensations).pop if !compensation && action[:compensates] && depth < MAX_DEPTH
    end
    row = record.merge("delivered" => outcome.fetch(:delivered))
    row["reason"] = outcome.fetch(:reason) unless outcome.fetch(:delivered)
    if compensation
      row["compensation"] = true
      row["compensation_failed"] = true unless outcome.fetch(:delivered)
    end
    world.fetch("sagas") << row
    saga_transition(runtime, world, home, saga, event, id, instance, "refused",
                    depth, cache, saga_state) if !compensation && !outcome.fetch(:delivered)
  end

  def query_rows(runtime, world, domain, route, event)
    aggregate_name, query_name = route.split(".", 2)
    aggregate = runtime.bluebooks.fetch(domain).aggregate(aggregate_name)
    query = aggregate.query(query_name).to_h
    args = IRRelationship.copy(event.fetch("payload"))
    query.fetch(:attributes).each do |attribute|
      name = attribute.fetch(:name).to_s
      args[name] = event.fetch("id") unless args.key?(name)
      value = args[name]
      args[name] = value.values.first if value.is_a?(Hash) && value.length == 1 && %w[String Integer Float].include?(attribute.fetch(:type))
    end
    rows = world.fetch("instances").filter_map do |key, state|
      next unless key.start_with?("#{domain}::#{aggregate_name}#")
      [key.split("#", 2).last, state]
    end
    query.fetch(:wheres).each do |where|
      raise "unsupported reaction query comparator #{where}" unless where.fetch(:op) == "eq"
      expected = scoped_value(where.fetch(:value), event, args)
      rows.select! { |_id, state| state.fetch(where.fetch(:field)) == expected }
    end
    if (order = query[:order_by])
      rows.sort_by! do |_id, state|
        value = state.fetch(order.fetch(:field))
        value.is_a?(Hash) && value.length == 1 ? value.values.first : value
      end
    end
    rows
  end

  def policy_actions(runtime, world, event, domain, policy)
    return [] if policy[:where_ast] && !IRRelationship.eval_ast(policy.fetch(:where_ast), {}, event.fetch("payload"))
    if policy[:for_each]
      query_rows(runtime, world, domain, policy.fetch(:for_each), event).map do |id, _state|
        target_aggregate = policy.fetch(:trigger_command).split(".").first
        key = target_aggregate.gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase
        [policy.fetch(:trigger_command), bind(policy.fetch(:with_spec), event, { key => id }, identity_heads(runtime, event))]
      end
    else
      [[policy.fetch(:trigger_command), bind(policy.fetch(:with_spec), event, {}, identity_heads(runtime, event))]]
    end
  end

  def react(runtime, world, events, depth = 0, cache = {}, saga_state = {}, correlation: nil)
    events.each do |event|
      domain = event.fetch("aggregate").split("::").first
      declarations(runtime).each do |home, policy|
        next unless matches?(policy.fetch(:on_event), event)
        next if depth >= MAX_DEPTH && !policy[:root]
        policy_actions(runtime, world, event, home, policy).each do |target, args|
          if policy[:target_domain]
            world.fetch("cross_domain") << { "policy" => policy.fetch(:name),
                                               "target_verb" => "#{policy.fetch(:target_domain)}::#{target}",
                                               "payload" => IRRelationship.copy(args) }
          end
          dispatch(runtime, world, policy[:target_domain] || home, target, args,
                   policy[:root] ? 0 : depth + 1, cache, saga_state,
                   explicit: !policy.fetch(:with_spec).empty?)
        end
      end
      saga_declarations(runtime).each do |home, saga|
        id = correlation || event.fetch("id")
        key = [home, saga.fetch(:name), id]
        if matches?(saga.fetch(:starts_on), event) && !saga_state.key?(key)
          saga_state[key] = { state: saga.fetch(:states).first, memory: IRRelationship.copy(event.fetch("payload")),
                              compensations: [] }
          world.fetch("sagas") << { "process_manager" => saga.fetch(:name), "on" => event.fetch("name"),
                                    "instance" => id, "born" => true, "state" => saga.fetch(:states).first }
        end
        instance = saga_state[key]
        if instance && matches?(saga.fetch(:ends_on), event)
          saga_state.delete(key)
          world.fetch("sagas") << { "process_manager" => saga.fetch(:name), "on" => event.fetch("name"),
                                    "instance" => id, "ended" => true }
        elsif instance
          saga_transition(runtime, world, home, saga, event, id, instance, event.fetch("name"),
                          depth, cache, saga_state)
        end
      end
    end
  end
end

require "json"
require "hecks"

# Compile a closed subset of the ancestral Bluebook IR into inspectable data.
# Unknown rule or mutation tags raise; no behavior falls back to Hecks dispatch.
module IRRelationship
  module_function

  class EvalFault < StandardError; end

  def int64?(value)
    value >= -(2**63) && value <= (2**63 - 1)
  end

  def copy(x) = JSON.parse(JSON.generate(x))

  def compile(aggregate, command_name)
    ir = aggregate.command(command_name).to_h
    instructions = []
    instructions << ["authorize", ir[:role]] unless ir[:role].nil?
    attributes = ir.fetch(:attributes).map { |a| a.fetch(:name).to_s }
    required = ir.fetch(:attributes).reject { |a| a.fetch(:optional) }.map { |a| a.fetch(:name).to_s }
    instructions << ["required", required, attributes]
    identity_args = aggregate.to_h.fetch(:identified_by).map { |path| path.split(".").first }
    instructions << ["known", (attributes + identity_args + ["id", aggregate.name.downcase]).uniq, attributes]
    ir.fetch(:attributes).each do |attribute|
      instructions << ["validate", attribute.fetch(:name).to_s, attribute.fetch(:type), attribute.fetch(:optional)]
    end
    ir.fetch(:attributes).each do |attribute|
      type = attribute.fetch(:type)
      next unless type.start_with?("Reference<")
      instructions << ["resolve_reference", attribute.fetch(:name).to_s,
                       type.delete_prefix("Reference<").delete_suffix(">")]
    end
    instructions << (ir[:references].nil? ? ["fresh"] : ["present"])
    ir.fetch(:mutations).select { |mutation| mutation.fetch(:op).to_s == "corrects" }.each do |mutation|
      instructions << ["corrects", mutation.fetch(:target).to_s]
    end
    if ir[:references].nil?
      ir.fetch(:attributes).map { |attribute| attribute.fetch(:name).to_s }.uniq.each do |field|
        next if ir.fetch(:mutations).any? { |m| m.fetch(:target).to_s == field }
        instructions << ["set", field, "argument", field]
      end
    end
    ir.fetch(:givens).each do |rule|
      instructions << ["given", rule.fetch(:ast), rule.fetch(:description)]
    end
    instructions << ["from", ir.fetch(:from)] if ir[:from]
    ir.fetch(:mutations).each do |mutation|
      case mutation.fetch(:op).to_s
      when "set"
        source = mutation.fetch(:source)
        raise "unsupported source #{source}" unless %w[argument state literal].include?(source.fetch(:kind))
        instructions << ["set", mutation.fetch(:target).to_s,
                         source.fetch(:kind), source.fetch(:kind) == "literal" ? source.fetch(:value) : source.fetch(:name).to_s]
      when "append"
        fields = mutation.fetch(:fields)
        target_type = aggregate.to_h.fetch(:attributes).find { |a| a.fetch(:name) == mutation.fetch(:target) }.fetch(:type)
        element = aggregate.value_object(target_type)&.to_h ||
                  aggregate.to_h.fetch(:entities).find { |e| e.fetch(:name) == target_type }
        element_fields = element.fetch(:attributes)
        sources = fields.transform_keys(&:to_s).transform_values do |value|
          if value.start_with?(":")
            ["argument", value.delete_prefix(":")]
          elsif (match = /\A\{([a-z_]+):\s*"([^"]*)"\}\z/.match(value))
            ["literal", { match[1] => match[2] }]
          elsif (match = /\A"([^"]*)"\z/.match(value))
            ["literal", match[1]]
          else
            raise "unsupported append field source #{value}"
          end
        end
        sources.each do |field, source|
          field_type = element_fields.find { |a| a.fetch(:name).to_s == field }.fetch(:type)
          source << field_type
        end
        instructions << ["append", mutation.fetch(:target).to_s, sources]
      when "increment", "decrement", "multiply", "clamp"
        source = mutation.fetch(:source)
        raise "unsupported numeric source #{source}" unless %w[argument literal].include?(source.fetch(:kind))
        instructions << ["numeric", mutation.fetch(:op).to_s, mutation.fetch(:target).to_s,
                         source.fetch(:kind), source[:name] || source[:value]]
      when "remove"
        source = mutation.fetch(:source)
        raise "unsupported remove source #{source}" unless source.fetch(:kind) == "argument"
        instructions << ["remove", mutation.fetch(:target).to_s, source.fetch(:name).to_s]
      when "corrects"
        next
      when "delegate"
        mapping = mutation.fetch(:fields).transform_keys(&:to_s).transform_values do |source|
          raise "unsupported delegation source #{source}" unless source.start_with?(":")
          source.delete_prefix(":")
        end
        instructions << ["delegate", mutation.fetch(:target).to_s, mapping]
      else raise "unsupported mutation #{mutation.fetch(:op)}"
      end
    end
    if (lifecycle = aggregate.to_h[:lifecycle])
      transitions = lifecycle.fetch(:transitions).select { |transition| transition.fetch(:command) == command_name }
      instructions << ["transition", lifecycle.fetch(:field),
                       transitions.map { |transition| [transition.fetch(:from_state), transition.fetch(:to_state)] }] unless transitions.empty?
    end
    ir.fetch(:ensures).each do |rule|
      instructions << ["ensures", rule.fetch(:ast), rule.fetch(:description)]
    end
    ir.fetch(:emits).each { |event| instructions << ["event", event] }
    instructions << ["commit"]
    instructions
  end

  def compile_query(aggregate, query_name)
    ir = aggregate.query(query_name).to_h
    program = ir.fetch(:attributes).map do |attribute|
      ["validate", attribute.fetch(:name).to_s, attribute.fetch(:type), attribute.fetch(:optional)]
    end
    ir.fetch(:wheres).each do |where|
      raise "unsupported query comparator #{where.fetch(:op)}" unless where.fetch(:op) == "lt"
      program << ["where_lt", where.fetch(:field), where.fetch(:value)]
    end
    if (order = ir[:order_by])
      raise "unsupported query ordering #{order}" unless order.fetch(:direction) == "asc"
      program << ["order", order.fetch(:field)]
    end
    program
  end

  def initial(aggregate)
    ir = aggregate.to_h
    state = ir.fetch(:attributes).to_h do |a|
      value = a.fetch(:list) ? [] : copy(a[:default])
      if value.nil? && !a.fetch(:list) && (vo = aggregate.value_object(a.fetch(:type)))
        fields = vo.to_h.fetch(:attributes)
        value = fields.to_h { |f| [f.fetch(:name).to_s, copy(f[:default])] } if fields.all? { |f| !f[:default].nil? }
      end
      if !a.fetch(:list) && !value.nil? && !value.is_a?(Hash) && (vo = aggregate.value_object(a.fetch(:type)))
        fields = vo.to_h.fetch(:attributes)
        value = { fields.first.fetch(:name).to_s => value } if fields.length == 1
      end
      [a.fetch(:name).to_s, value]
    end
    if (lifecycle = ir[:lifecycle])
      state[lifecycle.fetch(:field)] = lifecycle.fetch(:default)
    end
    state
  end

  def lookup(path, args, state)
    root = args.key?(path.first) ? args : state
    path.reduce(root) { |x, k| x.nil? ? nil : x.fetch(k) }
  end

  def eval_ast(ast, args, state)
    case ast.fetch("op")
    when "lookup" then lookup(ast.fetch("path"), args, state)
    when "size" then eval_ast(ast.fetch("receiver"), args, state).size
    when "int" then ast.fetch("value")
    when "nil" then nil
    when "str" then ast.fetch("value")
    when "add"
      left = eval_ast(ast.fetch("left"), args, state)
      right = eval_ast(ast.fetch("right"), args, state)
      result = left + right
      if result.is_a?(Integer) && !int64?(result)
        raise EvalFault, "addition overflowed: #{left} + #{right} does not fit in a 64-bit integer"
      end
      if result.is_a?(Float) && !result.finite?
        raise EvalFault, "addition overflowed: #{left.inspect} + #{right.inspect} is not a finite number"
      end
      result
    when "compare"
      l = eval_ast(ast.fetch("left"), args, state)
      r = eval_ast(ast.fetch("right"), args, state)
      compare(l, r, ast.fetch("cmp"))
    when "sign_test"
      compare(eval_ast(ast.fetch("receiver"), args, state), 0, ast.fetch("cmp"))
    when "not" then !eval_ast(ast.fetch("expr"), args, state)
    when "and" then eval_ast(ast.fetch("left"), args, state) && eval_ast(ast.fetch("right"), args, state)
    when "or" then eval_ast(ast.fetch("left"), args, state) || eval_ast(ast.fetch("right"), args, state)
    when "block_predicate"
      rows = eval_ast(ast.fetch("receiver"), args, state)
      parameter = ast.fetch("param")
      test = ->(row) { eval_ast(ast.fetch("predicate"), args.merge(parameter => row), state) }
      case ast.fetch("mode")
      when "any" then rows.any?(&test)
      when "all" then rows.all?(&test)
      when "none" then rows.none?(&test)
      else raise "unsupported block mode #{ast.fetch('mode')}"
      end
    when "empty" then eval_ast(ast.fetch("receiver"), args, state).empty?
    when "to_s" then eval_ast(ast.fetch("receiver"), args, state).to_s
    when "strip" then eval_ast(ast.fetch("receiver"), args, state).strip
    else raise "unsupported AST #{ast.fetch('op')}"
    end
  end

  def compare(left, right, cmp)
    raw = (cmp.fetch("less_than") && left < right) ||
          (cmp.fetch("equal") && left == right)
    cmp.fetch("negated") ? !raw : raw
  rescue ArgumentError => e
    raise EvalFault, e.message
  end

  def scalar_arg(args, name)
    value = args.fetch(name)
    value.is_a?(Hash) && value.keys == ["value"] ? value.fetch("value") : value
  end

  def display(value)
    value.nil? ? "nil" : JSON.generate(value)
  end

  def type_error(owner, field, type, value)
    "#{owner}.#{field} expects #{type}, got #{display(value)}"
  end

  def validate_value(aggregate, type, value)
    if type.start_with?("Reference<")
      return nil if value.is_a?(String)
      return ["TypeMismatch", type_error(type, "value", type, value)]
    end
    if value.nil?
      return ["TypeMismatch", type_error(type, "value", type, value)] if %w[String Integer Float TrueClass].include?(type)
      vo = aggregate.value_object(type)
      raise "unknown value object #{type}" unless vo
      first = vo.to_h.fetch(:attributes).find { |field| !field.fetch(:optional) }
      return ["TypeMismatch", type_error(type, first.fetch(:name), first.fetch(:type), nil)]
    end
    case type
    when "String" then return nil if value.is_a?(String)
    when "Integer"
      return nil if value.is_a?(Integer) && value >= -(2**63) && value <= (2**63 - 1)
    when "Float" then return nil if value.is_a?(Float) && value.finite?
    when "TrueClass" then return nil if value == true || value == false
    else
      vo = aggregate.value_object(type)
      raise "unknown value object #{type}" unless vo
      ir = vo.to_h
      ir.fetch(:attributes).each do |field|
        name = field.fetch(:name).to_s
        member = value.is_a?(Hash) ? value[name] : nil
        next if member.nil? && field.fetch(:optional)
        nested = field.fetch(:type)
        if %w[String Integer Float].include?(nested)
          valid = case nested
                  when "String" then member.is_a?(String)
                  when "Integer" then member.is_a?(Integer)
                  when "Float" then member.is_a?(Float) && member.finite?
                  end
          return ["TypeMismatch", type_error(type, name, nested, member)] unless valid
          if nested == "Integer" && (member < -(2**63) || member > 2**63 - 1)
            return ["TypeMismatch", "#{type}.#{name} must fit in a 64-bit integer, got #{member}"]
          end
        else
          error = validate_value(aggregate, nested, member)
          return error if error
        end
        pattern = field[:pattern]
        if pattern && !Regexp.new(pattern).match?(member)
          return ["TypeMismatch", "#{type}.#{name} must match #{pattern}, got #{display(member)}"]
        end
      end
      ir.fetch(:invariants).each do |rule|
        next if eval_ast(rule.fetch(:ast), {}, value)
        return ["InvariantViolation", "#{type} invariant violated — #{rule.fetch(:description)} (given #{JSON.generate(value)})"]
      end
      return nil
    end
    ["TypeMismatch", type_error(type, "value", type, value)]
  end

  def hydrate_references(world, runtime, domain_name, aggregate, state, depth = 4)
    return copy(state) if depth <= 0 || runtime.nil?
    hydrated = copy(state)
    aggregate.to_h.fetch(:attributes).each do |attribute|
      type = attribute.fetch(:type)
      next unless type.start_with?("Reference<")
      name = attribute.fetch(:name).to_s
      held = state[name]
      next if held.nil?
      target = type.delete_prefix("Reference<").delete_suffix(">")
      target_aggregate = runtime.bluebooks.fetch(domain_name).aggregate(target)
      next unless target_aggregate
      reference_id = held.is_a?(Hash) ? held.values.join(":") : held.to_s
      record = world.fetch("instances")["#{domain_name}::#{target}##{reference_id}"]
      hydrated[name] = hydrate_references(world, runtime, domain_name, target_aggregate, record, depth - 1) if record
    end
    hydrated
  end

  def run(program, world, aggregate, command_name, args, domain_name = "Pizzas", state_sources: :pre, role: nil, event_payload: nil, runtime: nil)
    identity_paths = aggregate.to_h.fetch(:identified_by)
    identity_field = identity_paths.first.split(".").first
    id_parts = identity_paths.map do |path|
      root, *tail = path.split(".")
      value = args.fetch(root) do
        identity_paths.length == 1 ? args.fetch(aggregate.name.downcase) {
          raise KeyError, "missing identity #{root} for #{domain_name}::#{aggregate.name}.#{command_name} args #{args.keys.inspect}"
        } : raise(KeyError, "missing identity #{root}")
      end
      tail.each do |field|
        value = value.is_a?(Hash) ? value.fetch(field) : (field == "value" ? value : raise(KeyError, "missing identity #{field}"))
      end
      value
    end
    id = id_parts.join(":")
    key = "#{domain_name}::#{aggregate.name}##{id}"
    state = world.fetch("instances")[key]
    before = state ? copy(state) : initial(aggregate)
    candidate = copy(before)
    rule_args = copy(args)
    pending = []
    program.each do |op, *parts|
      case op
      when "authorize"
        declared = Array(parts.fetch(0))
        if role && !declared.include?(role)
          return refusal(world, command_name,
                         "#{command_name} refused — role: #{declared.join(' or ')}, and the caller stated #{role}",
                         "Unauthorized", domain_name, aggregate.name)
        end
      when "required"
        missing = parts.fetch(0).reject { |name| args.key?(name) }
        unless missing.empty?
          missing = missing.sort
          return refusal(world, command_name,
                         "#{command_name} was not given #{missing.join(', ')} — it takes #{parts.fetch(1).join(', ')}",
                         "AbsentArgument", domain_name, aggregate.name)
        end
      when "known"
        unknown = args.keys - parts.fetch(0)
        unless unknown.empty?
          return refusal(world, command_name,
                         "#{command_name} does not declare #{unknown.sort.join(', ')} — it takes #{parts.fetch(1).join(', ')}",
                         "UnknownArgument", domain_name, aggregate.name)
        end
      when "validate"
        name, type, optional = parts
        next if optional && args[name].nil?
        error = validate_value(aggregate, type, args[name])
        if error && %w[String Integer Float TrueClass].include?(type)
          error = [error[0], type_error(aggregate.name, name, type, args[name])]
        end
        return refusal(world, command_name, error[1], error[0], domain_name, aggregate.name) if error
      when "resolve_reference"
        name, target = parts
        next unless args.key?(name) && !args[name].nil?
        reference_id = args[name].is_a?(Hash) ? args[name].values.join(":") : args[name].to_s
        referenced = world.fetch("instances")["#{domain_name}::#{target}##{reference_id}"]
        unless referenced
          target_aggregate = aggregate.respond_to?(:bluebook) ? aggregate.bluebook.aggregate(target) : nil
          heads = target_aggregate ? target_aggregate.to_h.fetch(:identified_by).join(", ") : "reference.value"
          return refusal(world, command_name, "no #{target} with #{heads} #{reference_id.to_json}",
                         "NotFound", domain_name, aggregate.name)
        end
        target_aggregate = runtime&.bluebooks&.fetch(domain_name)&.aggregate(target)
        rule_args[name] = target_aggregate ? hydrate_references(world, runtime, domain_name, target_aggregate, referenced) : copy(referenced)
      when "fresh"
        if state
          return refusal(world, command_name,
                         "#{command_name} creates a #{aggregate.name} that already exists — #{aggregate.to_h.fetch(:identified_by).join(', ')} #{id.to_json}",
                         "AlreadyExists", domain_name, aggregate.name)
        end
      when "present"
        unless state
          return refusal(world, command_name,
                         "no #{aggregate.name} with #{aggregate.to_h.fetch(:identified_by).join(', ')} #{id.to_json}",
                         "NotFound", domain_name, aggregate.name)
        end
      when "from"
        next if Array(parts.fetch(0)).include?(candidate.fetch("status"))
        current = candidate.fetch("status")
        return refusal(world, command_name,
                       "#{command_name} refused — status is #{current.to_json}, and #{command_name} moves it only from #{parts.fetch(0).to_json}",
                       "LifecycleRefused", domain_name, aggregate.name)
      when "given"
        next if eval_ast(parts.fetch(0), rule_args, candidate)
        return refusal(world, command_name, "#{command_name} refused — #{parts.fetch(1)}",
                       "GivenNotMet", domain_name, aggregate.name)
      when "set"
        target, source_kind, source_name = parts
        if source_kind == "literal"
          value = source_name
          attribute = aggregate.to_h.fetch(:attributes).find { |a| a.fetch(:name).to_s == target }
          if attribute && (vo = aggregate.value_object(attribute.fetch(:type)))
            fields = vo.to_h.fetch(:attributes)
            value = { fields.first.fetch(:name).to_s => value } if fields.length == 1
          end
          candidate[target] = copy(value)
        else
          source = source_kind == "argument" ? args : (state_sources == :pre ? before : candidate)
          candidate[target] = copy(source[source_name])
        end
      when "append"
        fields = parts.fetch(1).transform_values do |kind, source, field_type|
          value = kind == "argument" ?
            copy(%w[String Integer Float TrueClass].include?(field_type) ? scalar_arg(args, source) : args.fetch(source)) : copy(source)
          if kind == "literal" && !value.is_a?(Hash) && (vo = aggregate.value_object(field_type))
            sole = vo.to_h.fetch(:attributes)
            value = { sole.first.fetch(:name).to_s => value } if sole.length == 1
          end
          value
        end
        target = parts.fetch(0)
        element_type = aggregate.to_h.fetch(:attributes).find { |a| a.fetch(:name).to_s == target }.fetch(:type)
        entity = aggregate.to_h.fetch(:entities).find { |e| e.fetch(:name) == element_type }
        if entity
          identity_path = entity.fetch(:identified_by).first.split(".")
          identity_field = identity_path.first
          unless fields.key?(identity_field)
            held = candidate.fetch(target).map do |row|
              identity_path.reduce(row) { |value, part| value.fetch(part) }.to_i
            end
            next_id = held.max.to_i + 1
            fields[identity_field] = identity_path.length == 1 ? next_id : { identity_path.last => next_id }
          end
          if (lifecycle = entity[:lifecycle])
            fields[lifecycle.fetch(:field)] ||= lifecycle.fetch(:default)
          end
          entity.fetch(:invariants).each do |rule|
            next if eval_ast(rule.fetch(:ast), {}, fields)
            return refusal(world, command_name, "#{entity.fetch(:name)} refused — #{rule.fetch(:description)}",
                           "InvariantViolation", domain_name, aggregate.name)
          end
        end
        candidate.fetch(target) << copy(fields)
      when "remove"
        target, source_name = parts
        needle = args.fetch(source_name)
        candidate.fetch(target).reject! { |item| item == needle }
      when "corrects"
        event_name = parts.fetch(0)
        found = world.fetch("events").any? do |event|
          event.fetch("aggregate") == "#{domain_name}::#{aggregate.name}" &&
            event.fetch("id") == id && event.fetch("name") == event_name
        end
        unless found
          return refusal(world, command_name,
                         "#{command_name} refused — corrects #{event_name}, but #{domain_name}::#{aggregate.name} ##{id} has never emitted it",
                         "NothingToCorrect", domain_name, aggregate.name)
        end
      when "delegate"
        target, mapping = parts
        entity_name, entity_command_name = target.split(".", 2)
        entity = aggregate.entities.find { |item| item.hecks_name == entity_name }
        raise "unknown delegated entity #{entity_name}" unless entity
        entity_command = entity.command(entity_command_name).to_h
        entity_args = args.merge(mapping.transform_values { |source| copy(args.fetch(source)) })
        list_field = aggregate.to_h.fetch(:attributes).find { |attribute| attribute.fetch(:type) == entity_name }.fetch(:name).to_s
        identity_path = entity.to_h.fetch(:identified_by).first.split(".")
        sought = identity_path.reduce(entity_args) { |value, field| value.fetch(field) }
        row_index = candidate.fetch(list_field).index do |row|
          identity_path.reduce(row) { |value, field| value.fetch(field) } == sought
        end
        raise "delegated entity row missing #{entity_name}: #{sought.inspect} among #{candidate.fetch(list_field).map { |row| row[identity_path.first] }.inspect}" unless row_index
        row = candidate.fetch(list_field).fetch(row_index)
        entity_command.fetch(:givens).each do |rule|
          next if eval_ast(rule.fetch(:ast), entity_args.merge("parent" => candidate), row)
          return refusal(world, command_name, "#{entity_command_name} refused — #{rule.fetch(:description)}",
                         "GivenNotMet", domain_name, aggregate.name)
        end
        if entity_command[:from] && row.fetch(entity.to_h.fetch(:lifecycle).fetch(:field)) != entity_command[:from]
          raise "delegated lifecycle source mismatch"
        end
        changed = copy(row)
        entity_command.fetch(:mutations).each do |mutation|
          raise "unsupported delegated mutation #{mutation}" unless mutation.fetch(:op).to_s == "set"
          source = mutation.fetch(:source)
          value = source.fetch(:kind) == "argument" ? entity_args.fetch(source.fetch(:name).to_s) : source.fetch(:value)
          field = mutation.fetch(:target).to_s
          field_type = entity.to_h.fetch(:attributes).find { |attribute| attribute.fetch(:name).to_s == field }.fetch(:type)
          if !value.is_a?(Hash) && (vo = aggregate.value_object(field_type))
            sole = vo.to_h.fetch(:attributes)
            value = { sole.first.fetch(:name).to_s => value } if sole.length == 1
          end
          changed[field] = copy(value)
        end
        if (lifecycle = entity.to_h[:lifecycle])
          transition = lifecycle.fetch(:transitions).find do |option|
            option.fetch(:command) == entity_command_name && option.fetch(:from_state) == row.fetch(lifecycle.fetch(:field))
          end
          changed[lifecycle.fetch(:field)] = transition.fetch(:to_state) if transition
        end
        entity_command.fetch(:ensures).each do |rule|
          scope = entity_args.merge(changed).merge("old" => row)
          next if eval_ast(rule.fetch(:ast), {}, scope)
          return refusal(world, command_name, "#{entity_command_name} refused — #{rule.fetch(:description)}",
                         "EnsuresNotMet", domain_name, aggregate.name)
        end
        candidate.fetch(list_field)[row_index] = changed
        entity_command.fetch(:emits).each do |event_name|
          pending << { "name" => event_name, "aggregate" => "#{domain_name}::#{aggregate.name}", "id" => id,
                       "payload" => copy(entity_args) }
        end
      when "numeric"
        operation, target, source_kind, source_name = parts
        target_attr = aggregate.to_h.fetch(:attributes).find { |a| a.fetch(:name).to_s == target }
        target_type = target_attr.fetch(:type)
        scalar_field = aggregate.value_object(target_type).to_h.fetch(:attributes).first
        scalar_name = scalar_field.fetch(:name).to_s
        scalar_type = scalar_field.fetch(:type)
        operand = source_kind == "argument" ? args.fetch(source_name.to_s) : source_name
        operand = operand.fetch(scalar_name) if operand.is_a?(Hash) && operand.key?(scalar_name)
        unless operation == "clamp"
          valid_operand = scalar_type == "Integer" ? operand.is_a?(Integer) : operand.is_a?(Numeric)
          unless valid_operand
            return refusal(world, command_name, type_error(target_type, "value", scalar_type, operand),
                           "TypeMismatch", domain_name, aggregate.name)
          end
        end
        raw = before[target]
        current = raw.nil? ? 0 : (raw.is_a?(Hash) ? raw.fetch(scalar_name) : raw)
        result = case operation
                 when "increment" then current + operand
                 when "decrement" then current - operand
                 when "multiply" then current * operand
                 when "clamp" then [[current, operand.fetch(0)].max, operand.fetch(1)].min
                 else raise "unsupported numeric operation #{operation}"
                 end
        if result.is_a?(Integer) && !int64?(result)
          symbol = { "increment" => "+", "decrement" => "-", "multiply" => "*" }.fetch(operation, "?")
          raise EvalFault, "#{operation} overflowed: #{current} #{symbol} #{operand} does not fit in a 64-bit integer"
        end
        if result.is_a?(Float) && !result.finite?
          raise EvalFault, "#{operation} overflowed: #{current.inspect} + #{operand.inspect} is not a finite number"
        end
        candidate[target] = raw.is_a?(Hash) ? raw.merge(scalar_name => result) : { scalar_name => result }
      when "ensures"
        settled_scope = rule_args.merge(candidate).merge("old" => before)
        next if eval_ast(parts.fetch(0), {}, settled_scope)
        return refusal(world, command_name, "#{command_name} refused — #{parts.fetch(1)}",
                       "EnsuresNotMet", domain_name, aggregate.name)
      when "transition"
        field, options = parts
        selected = options.find { |source, _destination| source == candidate.fetch(field) }
        unless selected
          allowed = options.map(&:first).uniq.map(&:to_json).join(" or ")
          return refusal(world, command_name,
                         "#{command_name} refused — #{field} is #{candidate.fetch(field).to_json}, and #{command_name} moves it only from #{allowed}",
                         "LifecycleRefused", domain_name, aggregate.name)
        end
        candidate[field] = selected.fetch(1)
      when "event"
        pending << { "name" => parts.fetch(0), "aggregate" => "#{domain_name}::#{aggregate.name}",
                     "id" => id, "payload" => copy(event_payload || args) }
      when "commit"
        aggregate.to_h.fetch(:projected_fields).each do |projection|
          reference_id = candidate[projection.fetch(:reference)]
          next if reference_id.nil?
          reference_field = aggregate.to_h.fetch(:attributes).find { |a| a.fetch(:name).to_s == projection.fetch(:reference) }
          target = reference_field.fetch(:type).delete_prefix("Reference<").delete_suffix(">")
          referenced = world.fetch("instances")["#{domain_name}::#{target}##{reference_id}"]
          candidate[projection.fetch(:name)] = copy(referenced[projection.fetch(:remote_field)]) if referenced
        end
        world.fetch("instances")[key] = copy(candidate)
        world.fetch("events").concat(pending)
      else raise "unknown instruction #{op}"
      end
    end
    world
  rescue EvalFault => e
    refusal(world, command_name, e.message, "Fault", domain_name, aggregate.name)
  end

  def refusal(world, command, error, kind, domain_name = "Pizzas", aggregate_name = "Order")
    world.fetch("refusals") << { "verb" => "#{domain_name}::#{aggregate_name}.#{command}",
                                  "error" => error, "kind" => kind }
    world
  end

  def run_ad_hoc_query(world, runtime, query)
    aggregate_fqn = query.fetch("aggregate")
    field = query.fetch("field")
    operation = query.fetch("op")
    label = "filter #{aggregate_fqn}.#{field} #{operation}"
    unless %w[eq lt lte gt gte].include?(operation)
      world.fetch("refusals") << { "verb" => label, "error" => "unknown query comparator #{operation.to_json}", "kind" => "Fault" }
      return world
    end
    domain, aggregate_name = aggregate_fqn.split("::", 2)
    unless runtime.bluebooks[domain]&.aggregate(aggregate_name)
      world.fetch("refusals") << { "verb" => label, "error" => "unknown aggregate #{aggregate_fqn.to_json}", "kind" => "Fault" }
      return world
    end
    raise "ad hoc query success path unsupported"
  end

  def run_entity(world, aggregate, entity, command_name, args, domain_name)
    parent_id = aggregate.to_h.fetch(:identified_by).map do |path|
      path.split(".").reduce(args) { |value, field| value.fetch(field) }
    end.join(":")
    parent_key = "#{domain_name}::#{aggregate.name}##{parent_id}"
    parent = world.fetch("instances")[parent_key]
    raise "entity parent missing #{parent_key}" unless parent
    list_field = aggregate.to_h.fetch(:attributes).find { |attribute| attribute.fetch(:type) == entity.hecks_name }.fetch(:name).to_s
    identity_paths = entity.to_h.fetch(:identified_by)
    sought = identity_paths.map { |path| path.split(".").reduce(args) { |value, field| value.fetch(field) } }
    row_index = parent.fetch(list_field).index do |row|
      identity_paths.map { |path| path.split(".").reduce(row) { |value, field| value.fetch(field) } } == sought
    end
    raise "entity row missing #{entity.hecks_name}" unless row_index
    row = parent.fetch(list_field).fetch(row_index)
    command = entity.command(command_name).to_h
    command.fetch(:attributes).each do |attribute|
      name = attribute.fetch(:name).to_s
      error = validate_value(aggregate, attribute.fetch(:type), args[name])
      return refusal(world, "#{entity.hecks_name}.#{command_name}", error[1], error[0], domain_name, aggregate.name) if error
    end
    scope = args.merge("parent" => parent)
    command.fetch(:givens).each do |rule|
      next if eval_ast(rule.fetch(:ast), scope, row)
      return refusal(world, "#{entity.hecks_name}.#{command_name}",
                     "#{command_name} refused — #{rule.fetch(:description)}", "GivenNotMet", domain_name, aggregate.name)
    end
    candidate = copy(row)
    command.fetch(:mutations).each do |mutation|
      raise "unsupported entity mutation #{mutation}" unless mutation.fetch(:op).to_s == "set"
      candidate[mutation.fetch(:target).to_s] = copy(args.fetch(mutation.fetch(:source).fetch(:name).to_s))
    end
    entity.to_h.fetch(:invariants).each do |rule|
      next if eval_ast(rule.fetch(:ast), {}, candidate)
      return refusal(world, "#{entity.hecks_name}.#{command_name}",
                     "#{entity.hecks_name} refused — #{rule.fetch(:description)}", "InvariantViolation", domain_name, aggregate.name)
    end
    parent.fetch(list_field)[row_index] = candidate
    command.fetch(:emits).each do |event_name|
      world.fetch("events") << { "name" => event_name, "aggregate" => "#{domain_name}::#{aggregate.name}",
                                  "id" => parent_id, "payload" => args.slice(*command.fetch(:attributes).map { |a| a.fetch(:name).to_s }) }
    end
    world
  end

  def run_query(program, world, aggregate, query_name, args)
    rows = world.fetch("instances").map do |key, state|
      copy(state).merge("id" => key.split("#", 2).last)
    end
    program.each do |op, *parts|
      case op
      when "validate"
        name, type, optional = parts
        next if optional && args[name].nil?
        if (error = validate_value(aggregate, type, args[name]))
          refusal(world, query_name, error[1], error[0])
          world.fetch("queries") << { "rows" => nil, "error" => error[1] }
          return world
        end
      when "where_lt"
        field, source = parts
        raise "unsupported query source #{source}" unless source.start_with?(":")
        operand = args.fetch(source.delete_prefix(":"))
        operand = operand.values.first if operand.is_a?(Hash) && operand.length == 1
        rows.select! { |row| field.split(".").reduce(row) { |v, k| v.fetch(k) } < operand }
      when "order"
        rows.sort_by! do |row|
          key = parts.fetch(0).split(".").reduce(row) { |v, k| v.fetch(k) }
          key.is_a?(Hash) && key.length == 1 ? key.values.first : key
        end
      else raise "unsupported query instruction #{op}"
      end
    end
    world.fetch("queries") << { "rows" => rows }
    world
  end
end


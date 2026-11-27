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
    attributes = ir.fetch(:attributes).map { |a| a.fetch(:name).to_s }
    required = ir.fetch(:attributes).reject { |a| a.fetch(:optional) }.map { |a| a.fetch(:name).to_s }
    instructions << ["required", required, attributes]
    ir.fetch(:attributes).each do |attribute|
      instructions << ["validate", attribute.fetch(:name).to_s, attribute.fetch(:type), attribute.fetch(:optional)]
    end
    ir.fetch(:attributes).each do |attribute|
      type = attribute.fetch(:type)
      next unless type.start_with?("Reference<")
      instructions << ["resolve_reference", attribute.fetch(:name).to_s,
                       type.delete_prefix("Reference<").delete_suffix(">")]
    end
    identity_field = aggregate.to_h.fetch(:identified_by).first.split(".").first
    if ir[:references].nil? && !ir.fetch(:mutations).any? { |m| m.fetch(:target).to_s == identity_field }
      instructions << ["set", identity_field, "argument", identity_field]
    end
    instructions << ["from", ir.fetch(:from)] if ir[:from]
    ir.fetch(:givens).each do |rule|
      instructions << ["given", rule.fetch(:ast), rule.fetch(:description)]
    end
    ir.fetch(:mutations).each do |mutation|
      case mutation.fetch(:op).to_s
      when "set"
        source = mutation.fetch(:source)
        raise "unsupported source #{source}" unless %w[argument state].include?(source.fetch(:kind))
        instructions << ["set", mutation.fetch(:target).to_s,
                         source.fetch(:kind), source.fetch(:name).to_s]
      when "append"
        fields = mutation.fetch(:fields)
        raise "unsupported append fields #{fields}" unless fields.values.all? { |v| v.start_with?(":") }
        instructions << ["append", mutation.fetch(:target).to_s,
                         fields.transform_keys(&:to_s).transform_values { |v| v.delete_prefix(":") }]
      when "increment", "decrement", "multiply", "clamp"
        source = mutation.fetch(:source)
        raise "unsupported numeric source #{source}" unless %w[argument literal].include?(source.fetch(:kind))
        instructions << ["numeric", mutation.fetch(:op).to_s, mutation.fetch(:target).to_s,
                         source.fetch(:kind), source[:name] || source[:value]]
      when "remove"
        source = mutation.fetch(:source)
        raise "unsupported remove source #{source}" unless source.fetch(:kind) == "argument"
        instructions << ["remove", mutation.fetch(:target).to_s, source.fetch(:name).to_s]
      else raise "unsupported mutation #{mutation.fetch(:op)}"
      end
    end
    if (lifecycle = aggregate.to_h[:lifecycle])
      lifecycle.fetch(:transitions).each do |transition|
        next unless transition.fetch(:command) == command_name
        instructions << ["transition", lifecycle.fetch(:field), transition.fetch(:from_state),
                         transition.fetch(:to_state)]
      end
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
      [a.fetch(:name).to_s, value]
    end
    if (lifecycle = ir[:lifecycle])
      state[lifecycle.fetch(:field)] = lifecycle.fetch(:default)
    end
    state
  end

  def lookup(path, args, state)
    root = args.key?(path.first) ? args : state
    path.reduce(root) { |x, k| x.fetch(k) }
  end

  def eval_ast(ast, args, state)
    case ast.fetch("op")
    when "lookup" then lookup(ast.fetch("path"), args, state)
    when "size" then eval_ast(ast.fetch("receiver"), args, state).size
    when "int" then ast.fetch("value")
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
      return ["TypeMismatch", type_error(type, "value", type, value)] if %w[String Integer Float].include?(type)
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

  def run(program, world, aggregate, command_name, args, domain_name = "Pizzas", state_sources: :pre)
    identity_field = aggregate.to_h.fetch(:identified_by).first.split(".").first
    id = args.fetch(identity_field) { args.fetch(aggregate.name.downcase) }
    id = id.fetch("value") if id.is_a?(Hash)
    key = "#{domain_name}::#{aggregate.name}##{id}"
    state = world.fetch("instances")[key]
    before = state ? copy(state) : initial(aggregate)
    candidate = copy(before)
    rule_args = copy(args)
    pending = []
    program.each do |op, *parts|
      case op
      when "required"
        missing = parts.fetch(0).reject { |name| args.key?(name) }
        unless missing.empty?
          missing = missing.sort
          return refusal(world, command_name,
                         "#{command_name} was not given #{missing.join(', ')} — it takes #{parts.fetch(1).join(', ')}",
                         "AbsentArgument", domain_name, aggregate.name)
        end
      when "validate"
        name, type, optional = parts
        next if optional && args[name].nil?
        error = validate_value(aggregate, type, args[name])
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
        rule_args[name] = copy(referenced)
      when "from"
        next if candidate.fetch("status") == parts.fetch(0)
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
        source = source_kind == "argument" ? args : (state_sources == :pre ? before : candidate)
        candidate[target] = copy(source[source_name])
      when "append"
        fields = parts.fetch(1).transform_values { |source| scalar_arg(args, source) }
        candidate.fetch(parts.fetch(0)) << copy(fields)
      when "remove"
        target, source_name = parts
        needle = args.fetch(source_name)
        candidate.fetch(target).reject! { |item| item == needle }
      when "numeric"
        operation, target, source_kind, source_name = parts
        operand = source_kind == "argument" ? scalar_arg(args, source_name.to_s) : source_name
        unless operation == "clamp"
          target_attr = aggregate.to_h.fetch(:attributes).find { |a| a.fetch(:name).to_s == target }
          target_type = target_attr.fetch(:type)
          scalar_type = aggregate.value_object(target_type).to_h.fetch(:attributes).first.fetch(:type)
          valid_operand = scalar_type == "Integer" ? operand.is_a?(Integer) : operand.is_a?(Numeric)
          unless valid_operand
            return refusal(world, command_name, type_error(target_type, "value", scalar_type, operand),
                           "TypeMismatch", domain_name, aggregate.name)
          end
        end
        raw = before[target]
        current = raw.nil? ? 0 : (raw.is_a?(Hash) ? raw.fetch("value") : raw)
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
        candidate[target] = { "value" => result }
      when "ensures"
        settled_scope = candidate.merge("old" => before)
        next if eval_ast(parts.fetch(0), {}, settled_scope)
        return refusal(world, command_name, "#{command_name} refused — #{parts.fetch(1)}",
                       "EnsuresNotMet", domain_name, aggregate.name)
      when "transition"
        field, from, to = parts
        raise "transition source mismatch" unless candidate.fetch(field) == from
        candidate[field] = to
      when "event"
        pending << { "name" => parts.fetch(0), "aggregate" => "#{domain_name}::#{aggregate.name}",
                     "id" => id, "payload" => copy(args) }
      when "commit"
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


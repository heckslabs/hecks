module RustProjection
  module Projector
    module_function

    # Whether a creating command's state is fully determined by its payload and declared defaults.
    # Port of `Runtime::DependencyPlanning::Analyzer`'s `complete_state?`, over the exported IR
    # hash so codegen never needs live Bluebook objects or a call into Ruby.
    # Only meaningful for a command `creates_owner?` already accepted.
    def complete_state_creation?(aggregate, command, value_objects_by_name)
      owner_fields = creation_owner_fields(aggregate)
      payload_fields = command[:attributes].to_set { |a| a[:name].to_s }

      known_writes, disqualified = creation_known_writes(aggregate, command, owner_fields, payload_fields, value_objects_by_name)
      !disqualified && owner_fields.subset?(known_writes)
    end

    # Port of `complete_state? && state_independent?`: when true, the `AlreadyExists` check is
    # deferred until after givens, mutations, ensures and invariants have run.
    # Only meaningful for a command `creates_owner?` already accepted.
    def state_independent_creation?(aggregate, command, value_objects_by_name)
      return false unless complete_state_creation?(aggregate, command, value_objects_by_name)

      owner_fields = creation_owner_fields(aggregate)
      payload_fields = command[:attributes].to_set { |a| a[:name].to_s }

      rules = command[:givens].map { |rule| [rule, :before] } +
              command[:ensures].map { |rule| [rule, :after] } +
              aggregate[:invariants].map { |rule| [rule, :after] }

      rules.all? do |rule, phase|
        creation_rule_state_independent?(rule[:ast], phase, payload_fields, owner_fields)
      end
    end

    # Every field a fresh instance carries: declared attributes, the lifecycle field, and projected
    # fields (seeded outside this analysis, so they count as owner state).
    def creation_owner_fields(aggregate)
      fields = aggregate[:attributes].to_set { |a| a[:name].to_s }
      fields << aggregate[:lifecycle][:field].to_s if aggregate[:lifecycle]
      Array(aggregate[:projected_fields]).each { |field| fields << field[:name].to_s }
      fields
    end

    # Ports `analyze_initial_state`, `analyze_mutations` and `analyze_lifecycle`, in that order.
    # Returns `[known_writes, disqualified]`; the Analyzer's `unresolved` folds into one boolean.
    def creation_known_writes(aggregate, command, owner_fields, payload_fields, value_objects_by_name)
      known = Set.new
      aggregate[:attributes].each do |attr|
        known << attr[:name].to_s if creation_deterministic_initial_value?(attr, value_objects_by_name)
      end
      known << aggregate[:lifecycle][:field].to_s if aggregate[:lifecycle]

      # A creating command guarded by a lifecycle `from:` state reads prior state that is absent.
      disqualified = command[:from] && aggregate[:lifecycle] ? true : false

      command[:mutations].each do |mutation|
        target = mutation[:target].to_s
        unless owner_fields.include?(target)
          disqualified = true
          next
        end

        case creation_mutation_outcome(mutation, payload_fields, owner_fields)
        when :known then known << target
        when :unresolved then disqualified = true
        end
      end

      [known, disqualified]
    end

    # One mutation's outcome: `:known` (adds to known writes), `:unresolved` (disqualifies), or
    # `:state_read` (neither; stateful ops simply never enter known writes).
    def creation_mutation_outcome(mutation, payload_fields, owner_fields)
      case mutation[:op].to_s
      when "set"
        creation_classify_source(mutation[:source], payload_fields, owner_fields)
      when "append"
        # Stateful, so never a known write; only an undeclared source name in its fields
        # disqualifies.
        creation_append_outcome(mutation[:fields], payload_fields, owner_fields)
      when "increment", "decrement", "multiply", "clamp", "remove"
        # Stateful like `append`; no creating command in the corpus declares one.
        :state_read
      else
        :unresolved
      end
    end

    def creation_append_outcome(fields, payload_fields, owner_fields)
      fields.each_value do |wire_value|
        parsed = append_field_source(wire_value)
        next unless parsed.is_a?(Symbol)

        return :unresolved if creation_classify_symbol(parsed.to_s, payload_fields, owner_fields) == :unresolved
      end

      :state_read
    end

    # True for a list or optional attribute, or one with a non-nil default; otherwise true only
    # when its type is a value object whose every attribute has a non-nil default.
    def creation_deterministic_initial_value?(attr, value_objects_by_name)
      return true if [attr[:list], attr[:optional], !attr[:default].nil?].any?

      vo = value_objects_by_name[attr[:type]]
      return false unless vo

      vo[:attributes].all? { |field| !field[:default].nil? }
    end

    # Classifies a name as `:known` (payload argument), `:state_read` (owner field), or
    # `:unresolved`.
    def creation_classify_symbol(name, payload_fields, owner_fields)
      return :known if payload_fields.include?(name)
      return :state_read if owner_fields.include?(name)

      :unresolved
    end

    # Classifies a mutation's top-level `source:` (`{kind:, name:/value:}`).
    # A `"state"` source is `:known`, matching the live Analyzer, which has no StateRef branch;
    # "fixing" it would make this port disagree with the Analyzer it mirrors.
    def creation_classify_source(source, payload_fields, owner_fields)
      return creation_classify_symbol(source[:name].to_s, payload_fields, owner_fields) if source[:kind] == "argument"

      :known
    end

    # True when one rule's exported `ast` reads nothing that disqualifies state independence
    # (an unresolved path or a prior-state read).
    def creation_rule_state_independent?(ast, phase, payload_fields, owner_fields)
      creation_paths(ast, Set.new).all? do |path|
        creation_path_state_independent?(path, phase, payload_fields, owner_fields)
      end
    end

    # Collects dotted lookup paths from the JSON `ast`, mirroring `ExpressionReads.collect`.
    # Paths rooted at a name bound by a `block_predicate` param are skipped.
    def creation_paths(node, bound_names)
      case node
      when ::Hash
        case node["op"]
        when "lookup"
          root = node["path"].first.to_s
          bound_names.include?(root) ? [] : [node["path"].join(".")]
        when "block_predicate"
          creation_paths(node["receiver"], bound_names) +
            creation_paths(node["predicate"], bound_names | [node["param"].to_s])
        else
          node.each_value.flat_map { |value| creation_paths(value, bound_names) }
        end
      when ::Array
        node.flat_map { |value| creation_paths(value, bound_names) }
      else
        []
      end
    end

    # Port of `classify_path`. A `parent`/`old` head always disqualifies. A payload read is fine.
    # An owner-field read is fine only after mutation (`:after`): every owner field is a known
    # write by then, so a given (`:before`) is the one disqualifying case.
    # Unknown names disqualify.
    def creation_path_state_independent?(path, phase, payload_fields, owner_fields)
      head, = path.split(".", 2)

      case head
      when "parent", "old"
        false
      else
        return true if payload_fields.include?(head)
        return false unless owner_fields.include?(head)

        phase != :before
      end
    end
  end
end

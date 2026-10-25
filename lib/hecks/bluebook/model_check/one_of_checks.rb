require_relative "../one_of_union"
require_relative "../expression/ast_json"

module Hecks
  module Bluebook
    module ModelCheck
      # The check over a tagged reference (`reference_to one_of(A, B), as: :subject`, ADR 0122):
      # once anything branches on the subject's type, every variant of the union must be handled.
      # A branch is a command `given`/`ensures` of the owning aggregate comparing `subject.type`
      # with a name, or a read model `where` on the owning aggregate's `subject.type`.
      module OneOfChecks
        # Flags each tagged reference whose branches leave a variant unhandled, or name a type
        # the union does not hold.
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter to check
        # @return [Array<Finding>] one :one_of_branch_unhandled error per such reference
        def one_of_branch_findings(bluebook)
          bluebook.aggregates.flat_map do |aggregate|
            OneOfUnion.attributes(aggregate).filter_map { |attribute| one_of_branch_finding(bluebook, aggregate, attribute) }
          end
        end

        # @return [Finding, nil] the finding for one tagged reference, or nil when no branch
        #   names its type or every branch set covers the union exactly
        def one_of_branch_finding(bluebook, aggregate, attribute)
          tested = branched_types(bluebook, aggregate, attribute.name.to_s)
          return nil if tested.empty?

          variants = OneOfUnion.variants(aggregate, attribute)
          missing = variants - tested
          stray = tested - variants
          return nil if missing.empty? && stray.empty?

          Finding.new(kind: :one_of_branch_unhandled, severity: :error,
                      subject: "#{aggregate.hecks_name}.#{attribute.name}",
                      message: one_of_branch_message(attribute.name, missing, stray))
        end

        def one_of_branch_message(name, missing, stray)
          parts = []
          parts << "no branch handles #{missing.join(", ")}" unless missing.empty?
          parts << "a branch names #{stray.join(", ")}, which the union does not hold" unless stray.empty?
          "branches on #{name}.type, but #{parts.join("; ")} — handle every variant of the union"
        end

        # Every type name a branch of `aggregate` compares `<name>.type` with, each once.
        def branched_types(bluebook, aggregate, name)
          (rule_branch_types(aggregate, name) + where_branch_types(bluebook, aggregate, name)).uniq
        end

        # The names the owning aggregate's command rules compare `<name>.type` with.
        def rule_branch_types(aggregate, name)
          rules = aggregate.commands.flat_map { |command| Array(command.givens) + Array(command.ensures) }
          rules.flat_map { |rule| compared_types(rule_ast(rule), name) }
        end

        # A registry chapter is a round-trip product that keeps a rule's canonical text, not its
        # tree, so the tree is read again from the text.
        def rule_ast(rule)
          return rule.ast if rule.ast
          return nil if rule.canonical.to_s.empty?

          Expression::AstJson.emit_predicate(rule.canonical)
        end

        # The names a read model over the owning aggregate filters `<name>.type` by.
        def where_branch_types(bluebook, aggregate, name)
          clauses = read_models_over(bluebook, aggregate).flat_map(&:wheres)
          clauses.select { |clause| clause.field.to_s == "#{name}.type" }.map { |clause| clause.value.to_s }
        end

        # The read models that gather `aggregate` as one of their heads.
        def read_models_over(bluebook, aggregate)
          owner = aggregate.hecks_name.to_s
          bluebook.read_models.select { |model| model.aggregate_heads.any? { |head| head[:aggregate].to_s == owner } }
        end

        # Walks an expression tree for comparisons of the lookup `<name>.type` with a string.
        def compared_types(node, name)
          return node.flat_map { |child| compared_types(child, name) } if node.is_a?(Array)
          return [] unless node.is_a?(Hash)

          found = type_comparison(node, name)
          found + node.values.flat_map { |child| compared_types(child, name) }
        end

        def type_comparison(node, name)
          return [] unless field(node, :op) == "compare"

          sides = [field(node, :left), field(node, :right)]
          literal = sides.find { |side| field(side, :op) == "str" }
          sides.any? { |side| type_lookup?(side, name) } && literal ? [field(literal, :value).to_s] : []
        end

        def type_lookup?(side, name) = field(side, :op) == "lookup" && Array(field(side, :path)).map(&:to_s) == [name, "type"]

        # A key of an expression node, whether it was read with String or Symbol keys.
        def field(node, key)
          return nil unless node.is_a?(Hash)

          node.key?(key) ? node[key] : node[key.to_s]
        end
      end
    end
  end
end

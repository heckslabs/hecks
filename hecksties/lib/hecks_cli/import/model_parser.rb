# Hecks::Import::ModelParser
#
# Parses Rails model files using the Prism AST (built into Ruby 3.3+).
# Extracts associations, validations, enums, and AASM state machines from
# each class in a models directory — no Rails boot required.
#
#   ModelParser.new("app/models").parse
#   # => { "Pizza" => { associations: [...], validations: [...], enums: {...}, state_machine: {...} } }
#
require "prism"
require_relative "prism_helpers"

module Hecks
  module Import
    class ModelParser
      include PrismHelpers

      def initialize(models_dir)
        @models_dir = models_dir
      end

      def parse
        results = {}
        Dir[File.join(@models_dir, "*.rb")].each do |path|
          content = File.read(path)
          result = Prism.parse(content)
          next unless result.success?
          extract_classes(result.value).each do |class_name, data|
            results[class_name] = data
          end
        end
        results
      end

      private

      # Walk top-level statements for ClassNode entries. Only goes one level
      # deep so nested class bodies do not bleed into the outer class.
      def extract_classes(program_node)
        classes = {}
        program_node.statements.body.each do |node|
          next unless node.is_a?(Prism::ClassNode)
          name = class_name_from(node)
          next unless name
          calls = shallow_calls(node)
          classes[name] = {
            associations:  extract_associations(calls),
            validations:   extract_validations(calls),
            enums:         extract_enums(calls),
            state_machine: extract_state_machine(calls)
          }
        end
        classes
      end

      def class_name_from(class_node)
        path = class_node.constant_path
        path.respond_to?(:name) ? path.name.to_s : path.to_s
      end

      # Collect all CallNodes that are *direct* children of the class body
      # (i.e., inside the class statements but not inside nested blocks/defs).
      def shallow_calls(class_node)
        return [] if class_node.body.nil?
        stmts = class_node.body.is_a?(Prism::StatementsNode) ? class_node.body.body : []
        stmts.select { |n| n.is_a?(Prism::CallNode) }
      end

      # ------------------------------------------------------------------
      # Associations
      # ------------------------------------------------------------------

      def extract_associations(calls)
        calls.filter_map do |call|
          name_sym = call.name
          next unless %i[belongs_to has_many has_one].include?(name_sym)
          first = first_symbol_arg(call)
          next unless first
          assoc = { type: name_sym, name: first }
          assoc[:through] = kwarg_symbol(call, :through) if name_sym == :has_many
          assoc
        end
      end

      # ------------------------------------------------------------------
      # Validations
      # ------------------------------------------------------------------

      def extract_validations(calls)
        calls.filter_map do |call|
          next unless %i[validates validate].include?(call.name)
          field = first_symbol_arg(call)
          next unless field
          rules = {}
          rules[:presence]  = true if kwarg_true?(call, :presence)
          rules[:uniqueness] = true if kwarg_true?(call, :uniqueness)
          next if rules.empty?
          { field: field, rules: rules }
        end
      end

      # ------------------------------------------------------------------
      # Enums
      # ------------------------------------------------------------------

      def extract_enums(calls)
        enums = {}
        calls.each do |call|
          next unless call.name == :enum
          args = call.arguments&.arguments || []
          if args.first.is_a?(Prism::SymbolNode)
            field = args.first.unescaped
            enums[field] = enum_values_from_node(args[1]) if args[1]
          else
            collect_kwargs(call).each { |key, value| enums[key] = enum_values_from_node(value) }
          end
        end
        enums
      end

      def enum_values_from_node(node)
        case node
        when Prism::HashNode, Prism::KeywordHashNode
          node.elements.filter_map do |el|
            next unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
            el.key.unescaped
          end
        when Prism::ArrayNode
          node.elements.filter_map { |el| el.is_a?(Prism::SymbolNode) ? el.unescaped : nil }
        else
          []
        end
      end

      # ------------------------------------------------------------------
      # AASM state machine
      # ------------------------------------------------------------------

      def extract_state_machine(calls)
        aasm_call = calls.find { |c| c.name == :aasm }
        return nil unless aasm_call

        field   = kwarg_symbol(aasm_call, :column) || "status"
        initial = nil
        transitions = []

        block_calls(aasm_call).each do |inner|
          if inner.name == :state
            sym = first_symbol_arg(inner)
            initial = sym if sym && kwarg_true?(inner, :initial)
          elsif inner.name == :event
            event_name = first_symbol_arg(inner)
            block_calls(inner).each do |tc|
              next unless tc.name == :transitions
              from = kwarg_symbol(tc, :from)
              to   = kwarg_symbol(tc, :to)
              transitions << { event: event_name, from: from, to: to } if from && to
            end
          end
        end

        transitions.any? ? { field: field, initial: initial, transitions: transitions } : nil
      end
    end
  end
end

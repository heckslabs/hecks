module Hecks
  module Grammar
    # Finds the operators the language's own guards and invariants evaluate through, by walking
    # the evaluator's parse of each canonical expression. Extended onto `Hecks::Grammar`.
    module Operators
      # The operators the language's own guards and invariants (Bluebook, World and
      # the grammar chapters) evaluate through. Retiring one would leave the
      # language unable to read its own rules, so callers refuse it by name.
      #
      # @return [Hash{String => Array<String>}] each self-bearing operator symbol
      #   mapped to the `"Chapter Aggregate.command"`/`"Chapter Aggregate::ValueObject"`
      #   sites that use it
      def self_bearing_operators
        sites = Hash.new { |h, k| h[k] = [] }
        language_chapters.each do |chapter|
          chapter.aggregates.each do |aggregate|
            (command_sites(chapter, aggregate) + value_object_sites(chapter, aggregate)).each do |symbol, site|
              sites[symbol] << site
            end
          end
        end
        sites.transform_values(&:uniq)
      end

      # @return [Array<Class>] the Bluebook and World chapters plus every grammar chapter
      def language_chapters
        chapters = Bluebook::MetaValidator.grammar_registry
                                          .then { |reg| %w[Bluebook World].map { |name| reg.bluebook(name) } }
        (chapters + grammar_chapters).compact
      end

      # @return [Array<Array(String, String)>] each operator a command's givens use, with the
      #   command it is used in
      def command_sites(chapter, aggregate)
        aggregate.commands.flat_map do |command|
          site = "#{chapter.name} #{aggregate.name}.#{command.hecks_name}"
          command.givens.flat_map { |given| operators_in(given.canonical).map { |symbol| [symbol, site] } }
        end
      end

      # @return [Array<Array(String, String)>] each operator a value object's invariants use,
      #   with the value object it is used in
      def value_object_sites(chapter, aggregate)
        aggregate.value_objects.flat_map do |value_object|
          site = "#{chapter.name} #{aggregate.name}::#{value_object.hecks_name}"
          value_object.invariants.flat_map { |invariant| operators_in(invariant.canonical).map { |symbol| [symbol, site] } }
        end
      end

      # Every grammar/*.bluebook chapter, each booted alone in a scratch registry.
      #
      # @return [Array<Class>] each grammar chapter, booted alone in its own scratch
      #   registry
      def grammar_chapters
        Dir[File.join(Grammar::DIR, "*.bluebook")].map do |chapter|
          registry = Runtime::Registry.new
          load_chapter(registry, chapter)
          registry.bluebooks.values.first
        end
      end

      # Which admitted operators one canonical text evaluates through, found by
      # walking the evaluator's own parse.
      #
      # @param canonical [String] canonical expression text to parse
      # @return [Array<String>] operator symbols the expression evaluates through, or
      #   `[]` when `canonical` fails to parse
      def operators_in(canonical)
        evaluator = Bluebook::Expression::Evaluator
        begin
          node = evaluator.parse(canonical)
        rescue StandardError
          return []
        end
        walk_operators(node, evaluator).uniq
      end

      # One rule per closed node type of the AST, kept together so the whole operator
      # vocabulary reads in one place.
      # @param node [Object] an evaluator/resolver AST node, or a Struct fallback
      # @param evaluator [Module] `Bluebook::Expression::Evaluator`, passed through
      #   so nested calls don't re-resolve the constant
      # @return [Array<String>] operator symbols found in `node` and its children
      def walk_operators(node, evaluator)
        _type, operator, readers = operator_rules(evaluator).find { |type, *| node.is_a?(type) }
        return struct_operators(node, evaluator) unless readers

        own = operator.respond_to?(:call) ? [operator.call(node)] : Array(operator)
        own + readers.flat_map { |reader| walk_operators(node.public_send(reader), evaluator) }
      end

      # @return [Array<Array>] each node type with the operator it contributes (a String, a
      #   callable reading it off the node, or nil) and the readers of its child nodes
      def operator_rules(evaluator)
        resolver = Bluebook::Expression::Resolver
        [[evaluator::Or, "||", %i[left right]], [evaluator::And, "&&", %i[left right]],
         [evaluator::Not, "!", %i[node]], [evaluator::Compare, ->(node) { node.operator.symbol }, %i[left right]],
         [evaluator::Include, ".include?", %i[haystack needle]], [evaluator::Resolve, nil, %i[expr]],
         [resolver::Addition, "+", %i[left right]], [resolver::Subtraction, "-", %i[left right]],
         [resolver::Multiplication, "*", %i[left right]], [resolver::Division, "/", %i[left right]],
         [resolver::Modulo, ".modulo", %i[receiver divisor]]]
      end

      # @return [Array<String>] operators found in the members of a Struct node; none for any
      #   other node
      def struct_operators(node, evaluator)
        return [] unless node.is_a?(Struct)

        node.members.flat_map { |member| walk_operators(node[member], evaluator) }
      end
    end
  end
end

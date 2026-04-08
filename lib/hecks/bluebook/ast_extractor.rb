# Hecks::AstExtractor
#
# Extracts domain structure from Bluebook DSL files using Ruby's built-in
# AST parser. Reads the file, parses it into an abstract syntax tree via
# RubyVM::AbstractSyntaxTree, then walks the tree to extract domain name,
# aggregates, attributes, commands, events, policies, services, specifications,
# references, value objects, entities, validations, and world concerns --
# all without eval.
#
# Returns a plain hash IR that mirrors the BluebookBuilder's output, suitable
# for static analysis, linting, or feeding into the normal Domain constructor.
#
#   result = Hecks::AstExtractor.extract_file("examples/pizzas/PizzasBluebook")
#   result[:name]        # => "Pizzas"
#   result[:aggregates]  # => [{ name: "Pizza", attributes: [...], ... }, ...]
#
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::AstParagraph,
  base_dir: File.expand_path("ast_extractor", __dir__)
)

module Hecks
  class AstExtractor
    include NodeReaders

    # Extract domain structure from a Bluebook source string.
    #
    # @param source [String] Ruby source code containing a Hecks.bluebook block
    # @return [Hash] domain IR hash with :name, :aggregates, :policies, etc.
    def self.extract(source)
      new(source).extract
    end

    # Extract domain structure from a Bluebook file path.
    #
    # @param path [String] filesystem path to a Bluebook file
    # @return [Hash] domain IR hash
    def self.extract_file(path)
      extract(File.read(path))
    end

    def initialize(source)
      @source = source
    end

    def extract
      ast = RubyVM::AbstractSyntaxTree.parse(@source)
      domain_call = find_domain_call(ast)
      return empty_domain unless domain_call

      DomainVisitor.new(domain_call).visit
    end

    private

    def find_domain_call(node)
      return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      if domain_call?(node)
        return node
      end

      node.children.each do |child|
        result = find_domain_call(child)
        return result if result
      end
      nil
    end

    def domain_call?(node)
      return false unless node.type == :ITER

      call = node.children[0]
      return false unless call.type == :CALL

      receiver = call.children[0]
      method_name = call.children[1]
      receiver.type == :CONST && receiver.children[0] == :Hecks && method_name == :domain
    end

    def empty_domain
      { name: nil, aggregates: [], policies: [], services: [],
        views: [], workflows: [], world_goals: [] }
    end
  end
end

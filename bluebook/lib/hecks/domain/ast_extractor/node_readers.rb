# Hecks::AstExtractor::NodeReaders
#
# Low-level AST node reading utilities. Extracts literal values, constant
# names, method arguments, keyword arguments, and block bodies from
# RubyVM::AbstractSyntaxTree nodes. Shared by all visitor modules.
#
#   include NodeReaders
#   read_literal(lit_node)    # => :name
#   read_const(const_node)    # => "String"
#   read_string(str_node)     # => "Pizza"
#
module Hecks
  class AstExtractor
    module NodeReaders
      # Read a literal value from a LIT node.
      # @param node [RubyVM::AbstractSyntaxTree::Node]
      # @return [Object] the literal value (Symbol, Integer, Float, etc.)
      def read_literal(node)
        return nil unless node&.type == :LIT
        node.children[0]
      end

      # Read a string value from a STR node.
      # @param node [RubyVM::AbstractSyntaxTree::Node]
      # @return [String, nil]
      def read_string(node)
        return nil unless node&.type == :STR
        node.children[0]
      end

      # Read a constant name from a CONST node, returning the string form.
      # @param node [RubyVM::AbstractSyntaxTree::Node]
      # @return [String, nil] e.g. "String", "Integer", "Float"
      def read_const(node)
        return nil unless node&.type == :CONST
        node.children[0].to_s
      end

      # Read a scalar value from any node type (LIT, STR, CONST, TRUE, FALSE, NIL).
      # @param node [RubyVM::AbstractSyntaxTree::Node]
      # @return [Object, nil]
      def read_value(node)
        return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
        case node.type
        when :LIT   then node.children[0]
        when :STR   then node.children[0]
        when :CONST then node.children[0].to_s
        when :TRUE  then true
        when :FALSE then false
        when :NIL   then nil
        else nil
        end
      end

      # Read positional arguments from an argument LIST node.
      # @param node [RubyVM::AbstractSyntaxTree::Node] a LIST node
      # @return [Array<Object>] extracted values
      def read_args(node)
        return [] unless node&.type == :LIST
        node.children.compact.filter_map { |c| read_arg_value(c) }
      end

      # Read a single argument value, handling FCALL for list_of().
      def read_arg_value(child)
        return nil unless child.is_a?(RubyVM::AbstractSyntaxTree::Node)
        case child.type
        when :LIT, :STR, :CONST, :TRUE, :FALSE, :NIL
          read_value(child)
        when :FCALL
          read_fcall_value(child)
        when :HASH
          read_hash(child)
        else
          nil
        end
      end

      # Read an FCALL node value (e.g., list_of("Topping")).
      def read_fcall_value(node)
        method = node.children[0]
        if method == :list_of
          inner = read_args(node.children[1])
          { list: inner.first }
        else
          nil
        end
      end

      # Read keyword arguments from a HASH node.
      # @param node [RubyVM::AbstractSyntaxTree::Node] a HASH node
      # @return [Hash{Symbol => Object}]
      def read_hash(node)
        return {} unless node&.type == :HASH
        list = node.children[0]
        return {} unless list&.type == :LIST
        pairs = list.children.compact
        result = {}
        pairs.each_slice(2) { |k, v| result[read_value(k)] = read_value(v) if k && v }
        result
      end

      # Collect block statements from a SCOPE node's body.
      # Returns BLOCK children or a single-statement array.
      def block_statements(scope_node)
        return [] unless scope_node&.type == :SCOPE
        body = scope_node.children[2]
        return [] unless body
        body.type == :BLOCK ? body.children : [body]
      end

      # Check if a node is an FCALL/CALL with the given method name.
      def method_call?(node, name)
        return false unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
        (node.type == :FCALL || node.type == :CALL) && node.children.first == name ||
          (node.type == :FCALL && node.children[0] == name)
      end

      # Check if a node is an ITER wrapping an FCALL with the given method name.
      def iter_call?(node, name)
        return false unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
        node.type == :ITER && node.children[0]&.type == :FCALL &&
          node.children[0].children[0] == name
      end

      # Extract method name from FCALL or ITER>FCALL.
      def call_method_name(node)
        return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
        if node.type == :FCALL
          node.children[0]
        elsif node.type == :ITER && node.children[0]&.type == :FCALL
          node.children[0].children[0]
        end
      end

      # Extract positional args from FCALL or ITER>FCALL.
      def call_args(node)
        fcall = node.type == :ITER ? node.children[0] : node
        return [] unless fcall&.type == :FCALL
        args_node = fcall.children[1]
        read_args(args_node)
      end

      # Extract keyword args from FCALL. They appear as the last HASH in the LIST.
      def call_kwargs(node)
        fcall = node.type == :ITER ? node.children[0] : node
        return {} unless fcall&.type == :FCALL
        args_node = fcall.children[1]
        return {} unless args_node&.type == :LIST
        last_child = args_node.children.compact.last
        return {} unless last_child.is_a?(RubyVM::AbstractSyntaxTree::Node)
        last_child.type == :HASH ? read_hash(last_child) : {}
      end
    end
  end
end

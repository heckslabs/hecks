# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # Reads a method definition's Ripper nodes: the names of its parameters and whether its body
      # raises.
      module Signature
        module_function

        # @param params [Array, nil] the parameter node of a `def`
        # @return [Array(Array<String>, String)] the parameter names, and the block parameter's name
        def parameter_names(params)
          params = params[1] if params.is_a?(Array) && params[0] == :paren
          return [[], nil] unless params.is_a?(Array) && params[0] == :params

          [positional_names(params) + keyword_names(params), splat_name(params[7]).first]
        end

        # @param node [Object] a Ripper node
        # @return [Boolean] whether the node, outside any nested `def`, calls `raise`
        def raises?(node)
          return false unless node.is_a?(Array)
          return false if %i[def defs].include?(node[0])

          call = %i[command fcall vcall].include?(node[0]) && node[1].is_a?(Array) && node[1][1] == "raise"
          call || node.any? { |child| raises?(child) }
        end

        # @return [Array<String>] required, optional, rest and post parameter names
        def positional_names(params)
          _, required, optional, rest, post = params
          idents(required) + Array(optional).map { |pair| pair[0][1] } + splat_name(rest) + idents(post)
        end

        # @return [Array<String>] keyword and keyword-rest parameter names
        def keyword_names(params)
          keywords, keyrest = params.values_at(5, 6)
          Array(keywords).map { |pair| pair[0][1].chomp(":") } + splat_name(keyrest)
        end

        # @return [Array<String>] the names in a list of identifier nodes
        def idents(list)
          Array(list).select { |item| item.is_a?(Array) && item[0] == :@ident }.map { |item| item[1] }
        end

        # `rest`/`keyrest`/`block` are each either nil, an unnamed splat (`*`, `**`, `&`), or a
        # one-element `[:@ident, name, pos]` node wrapping the name.
        #
        # @return [Array<String>] the name, or nothing when the splat is unnamed
        def splat_name(node)
          node.is_a?(Array) && node[1].is_a?(Array) ? [node[1][1]] : []
        end
      end
    end
  end
end

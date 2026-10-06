# frozen_string_literal: true

require_relative "../../tools"
require_relative "signature"

module Hecks
  module Tools
    module CommentStyle
      # Walks a Ripper s-expression collecting method and type definitions
      # along with the visibility each method ends up with.
      class Walker
        Scope = Struct.new(:nesting, :visibility)
        VISIBILITY_WORDS = %w[private protected private_class_method].freeze

        attr_reader :methods, :types

        def initialize
          @methods = []
          @types = []
          @private_names = Set.new
        end

        # Visits one Ripper node, recording any method or type it defines.
        def walk(node, scope)
          return unless node.is_a?(Array)

          case node[0]
          when :class, :module, :sclass then walk_scope(node, scope)
          when :def, :defs then walk_definition(node, scope)
          when :vcall, :var_ref then switch_visibility(node, scope)
          when :command, :method_add_arg then visibility_call?(node, scope) || walk_children(node, scope)
          else walk_children(node, scope)
          end
        end

        private

        def walk_children(node, scope)
          node.each { |child| walk(child, scope) if child.is_a?(Array) }
        end

        def walk_scope(node, scope)
          case node[0]
          when :class then open_type(node[1], node[3], scope)
          when :module then open_type(node[1], node[2], scope)
          else walk_body(node[2], Scope.new(scope.nesting, :public))
          end
        end

        def walk_definition(node, scope)
          if node[0] == :def
            record(node[1], node[2], node[3], scope.visibility, scope.nesting)
          else
            record(node[3], node[4], node[5], :public, scope.nesting)
          end
        end

        # `private :name` can follow the definition, so it is applied once the
        # whole body has been seen.
        def walk_body(body, scope)
          first = @methods.length
          outer = @private_names
          @private_names = Set.new
          walk_children(body, scope) if body.is_a?(Array)
          @methods[first..].each { |m| m.visibility = :private if @private_names.include?(m.name) }
          @private_names = outer
        end

        def open_type(const, body, scope)
          nesting = scope.nesting + [const_name(const)]
          @types << TypeDef.new(nesting.join("::"), line_of(const), namespace_only?(body))
          walk_body(body, Scope.new(nesting, :public))
        end

        # A type whose body holds only nested types is a namespace, not something to document.
        def namespace_only?(body)
          statements = body.is_a?(Array) && body[0] == :bodystmt ? Array(body[1]) : []
          statements.all? { |s| !s.is_a?(Array) || %i[class module void_stmt].include?(s[0]) }
        end

        def const_name(node)
          node.flatten.grep(String).join("::")
        end

        def line_of(node)
          position = node.flatten.each_cons(2).find { |a, b| a.is_a?(Integer) && b.is_a?(Integer) }
          position ? position[0] : 0
        end

        def switch_visibility(node, scope)
          case node[1].is_a?(Array) ? node[1][1] : nil
          when "private", "protected" then scope.visibility = :private
          when "public", "module_function" then scope.visibility = :public
          end
        end

        def visibility_call?(node, scope)
          return false unless visibility_head?(node)

          arguments = node[0] == :command ? node[2] : node.dig(2, 1)
          Array(arguments.is_a?(Array) ? arguments[1] : nil).each { |argument| mark_private(argument, scope) }
          true
        end

        def visibility_head?(node)
          head = node[0] == :command ? node[1] : node.dig(1, 1)
          head.is_a?(Array) && head[0] == :@ident && VISIBILITY_WORDS.include?(head[1])
        end

        def mark_private(argument, scope)
          return unless argument.is_a?(Array)

          case argument[0]
          when :def, :defs then record_private(argument, scope)
          when :symbol_literal, :dyna_symbol then @private_names << argument.flatten.grep(String).last
          else walk(argument, scope)
          end
        end

        def record_private(argument, scope)
          if argument[0] == :def
            record(argument[1], argument[2], argument[3], :private, scope.nesting)
          else
            record(argument[3], argument[4], argument[5], :private, scope.nesting)
          end
        end

        def record(name_node, params, body, visibility, nesting)
          names, block = Signature.parameter_names(params)
          @methods << MethodDef.new(name_node[1], name_node[2][0], names, visibility, Signature.raises?(body), block,
                                    nesting.join("::"))
        end
      end
    end
  end
end

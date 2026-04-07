module Hecks
  module Generators
    module Infrastructure
      class FrameworkGemGenerator
        # Hecks::Generators::Infrastructure::FrameworkGemGenerator::SkeletonGenerator
        #
        # Generates a skeleton Ruby file from a chapter aggregate's IR fields.
        # Uses namespace, superclass, mixins, and
        # method_name to produce skeletons without reading actual source files.
        #
        #   skel = SkeletonGenerator.new(aggregate).generate
        #   puts skel
        #
        class SkeletonGenerator
          def initialize(aggregate, actual_path = nil)
            @aggregate   = aggregate
            @actual_path = actual_path
          end

          def generate
            lines = []
            lines << doc_comment
            lines.concat(open_nesting)
            lines << indent(depth, body_declaration)
            lines.concat(mixin_lines)
            lines.concat(method_stubs)
            lines << indent(depth, "end")
            lines.concat(close_nesting)
            lines.join("\n") + "\n"
          end

          private

          # Determines whether to emit `class` or `module`.
          # First checks IR fields (superclass/mixins → class).
          # Falls back to naming conventions as a generator heuristic:
          # Builder/Generator/Adapter → class, DSL/Mixin/Helpers/Boot/Setup → module.
          # These conventions never appear in the Bluebook DSL or IR.
          def use_class?
            return true if @aggregate.superclass || @aggregate.mixins.any?

            name = @aggregate.name
            return true  if name.end_with?("Builder", "Generator", "Adapter")
            return false if name.end_with?("DSL", "Mixin", "Helpers", "Registry",
                                           "Boot", "Setup")
            return false if name.start_with?("Hecks") && !name.include?("::")

            false
          end

          def namespace_parts
            @namespace_parts ||= if @aggregate.namespace
              @aggregate.namespace.split("::")
            elsif @actual_path && File.exist?(@actual_path)
              extract_nesting_from_file
            else
              []
            end
          end

          def depth
            namespace_parts.size
          end

          def fqn
            parts = namespace_parts + [@aggregate.name]
            parts.join("::")
          end

          def doc_comment
            lines = []
            lines << "# #{fqn}"
            lines << "#"
            lines << "# #{@aggregate.description}" if @aggregate.description
            lines << "#"
            lines << ""
            lines.join("\n")
          end

          def body_declaration
            keyword = use_class? ? "class" : "module"
            decl = "#{keyword} #{@aggregate.name}"
            decl += " < #{@aggregate.superclass}" if @aggregate.superclass
            decl
          end

          def mixin_lines
            @aggregate.mixins.map do |m|
              indent(depth + 1, "include #{m}")
            end
          end

          def method_stubs
            lines = []
            unless use_class?
              lines << ""
              lines << indent(depth + 1, "module_function")
            end

            @aggregate.commands.each do |cmd|
              method = cmd.method_name || Hecks::Utils.underscore(cmd.name)
              params = cmd.attributes.map { |a| "#{a.name}:" }
              sig = params.empty? ? method : "#{method}(#{params.join(', ')})"
              lines << ""
              lines << indent(depth + 1, "def #{sig}")
              lines << indent(depth + 2, "raise NotImplementedError")
              lines << indent(depth + 1, "end")
            end
            lines
          end

          def open_nesting
            namespace_parts.each_with_index.map do |part, i|
              indent(i, "module #{part}")
            end
          end

          def close_nesting
            namespace_parts.each_index.reverse_each.map do |i|
              indent(i, "end")
            end
          end

          def indent(n, text)
            ("  " * n) + text
          end

          def extract_nesting_from_file
            return [] unless @actual_path && File.exist?(@actual_path)

            wrappers = []
            File.foreach(@actual_path) do |line|
              stripped = line.strip
              if stripped =~ /\A(module|class)\s+(\w+)/
                wrappers << $2
              end
            end
            # Last one is the body (the aggregate itself), rest are wrappers
            wrappers.pop if wrappers.any?
            wrappers
          end
        end
      end
    end
  end
end

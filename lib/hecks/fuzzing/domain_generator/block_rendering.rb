module Hecks
  module Fuzzing
    module DomainGenerator
      # Renders the blocks a blueprint nests inside aggregates and entities: value objects,
      # lifecycles and commands.
      module BlockRendering
        def render_value_object(name, value_object, indent)
          body = value_object_body(name, value_object)
          ["", "#{indent}value_object #{name.inspect} do", *body.map { |line| "#{indent}  #{line}" }, "#{indent}end"]
        end

        def value_object_body(name, value_object)
          case value_object["kind"]
          when "string"   then string_body(name)
          when "positive" then ["attribute :value, Integer", "invariant(#{"a #{name} is positive".inspect}) { value.positive? }"]
          when "integer"  then ["attribute :value, Integer"]
          when "closed"   then ["attribute :value, String, one_of: #{value_object["members"].inspect}"]
          end
        end

        def string_body(name)
          ["attribute :value, String, pattern: '[^ \\t\\n\\r]'",
           "invariant(#{"a #{name} is not blank".inspect}) { !value.to_s.empty? }"]
        end

        def render_lifecycle(lifecycle, indent)
          ["", "#{indent}lifecycle :#{lifecycle["field"]}, default: #{lifecycle["default"].inspect} do",
           *lifecycle["transitions"].map { |transition| render_transition(transition, indent) },
           "#{indent}end"]
        end

        def render_transition(transition, indent)
          from = transition["from"].size == 1 ? transition["from"].first.inspect : transition["from"].inspect
          "#{indent}  transition #{transition["command"].inspect} => #{transition["to"].inspect}, from: #{from}"
        end

        def render_command(command, self_name, indent)
          ["", "#{indent}command #{command["name"].inspect} do",
           *command_header(command, self_name, indent),
           *command_body(command, indent),
           "#{indent}end"]
        end

        # A command's role, goal and references.
        def command_header(command, self_name, indent)
          out = []
          out << "#{indent}  role #{command["role"].inspect}" if command["role"]
          out << "#{indent}  goal #{"#{command["name"]} it".inspect}"
          out << "#{indent}  reference_to #{self_name}" if self_name && !command["creates"]
          out + command["references"].map { |target| "#{indent}  reference_to #{target}" }
        end

        # A command's arguments, givens, sets and emitted events.
        def command_body(command, indent)
          [*command["args"].map { |arg| "#{indent}  #{render_attribute(arg)}" },
           *command["givens"].map { |given| "#{indent}  given(#{given["label"].inspect}) { #{given["expr"]} }" },
           *command["sets"].map { |set| "#{indent}  #{render_set(set)}" },
           *command["emits"].map { |event| "#{indent}  emits #{event.inspect}" }]
        end

        def render_set(set)
          return "sets :#{set["target"]}, to: :#{set["to"]}" if set["to"]
          return "sets :#{set["target"]}, append: { #{set["append"].map { |k, v| "#{k}: :#{v}" }.join(", ")} }" if set["append"]

          "sets :#{set["target"]}"
        end
      end
    end
  end
end

module Hecks
  module Projector
    module NarrateProjector
      # The prose for the goals an `.examples` file declares (ADR 0173): each goal as a use case,
      # its first example the main scenario and the rest its extensions. Every line is quoted from
      # the file; `hecks-parse examples` has already checked it against the bluebook.
      module UseCases
        GOAL    = /\A(\s*)Goal:\s*(.+?)\s*\z/
        EXAMPLE = /\A\s*Example:\s*(.+?)\s*\z/
        STEP    = /\A\s*(Given|When|Then|And)\s+(.+?)\s*\z/
        INDENT  = /\A\s*/

        module_function

        # The "Use cases" section, or `nil` when no file declares a goal.
        #
        # @param paths [Array<String>] `.examples` files
        # @param depth [Integer] the section's heading level
        # @return [String, nil] Markdown
        def narrative(paths, depth)
          goals = Array(paths).flat_map { |path| goals_in(File.readlines(path, chomp: true)) }
          return nil if goals.empty?

          [DocsProjector.h(depth, "Use cases"), *goals.map { |goal| goal_text(goal, depth + 1) }].join("\n\n")
        end

        # @param lines [Array<String>] one `.examples` file
        # @return [Array<Hash>] each goal with its examples, each example with its step lines
        def goals_in(lines)
          open = nil
          lines.each_with_object([]) do |line, goals|
            open = follow(line, open, goals) unless line.strip.empty?
          end
        end

        # Reads one line against the goal still open, answering the goal open after it: a `Goal:`
        # opens one, a line indented under it belongs to it, any other line closes it.
        def follow(line, open, goals)
          if (goal = line.match(GOAL))
            goals << { indent: goal[1].size, goal: goal[2], examples: [] }
            return goals.last
          end
          return nil unless open && indent_of(line) > open[:indent]

          add_to(open, line)
          open
        end

        # Files one line of a goal: an example under it, or a step of its latest example.
        def add_to(goal, line)
          if (example = line.match(EXAMPLE))
            goal[:examples] << { title: example[1], steps: [] }
          elsif (step = line.match(STEP)) && goal[:examples].any?
            goal[:examples].last[:steps] << "#{step[1]} #{step[2]}"
          end
        end

        def indent_of(line) = line[INDENT].size

        def goal_text(goal, depth)
          main, *extensions = goal[:examples]
          [DocsProjector.h(depth, goal[:goal]), scenario("Main scenario", main),
           *extensions.map { |extension| scenario("Extension", extension) }].compact.join("\n\n")
        end

        def scenario(label, example)
          return nil unless example

          ["**#{label}: #{example[:title]}**", *example[:steps].map { |step| "- #{step}" }].join("\n")
        end
      end
    end
  end
end

# frozen_string_literal: true

module Hecks
  module Tools
    module AgentRoles
      # Renders one `RoleFile` row as the text of its role file.
      module Render
        # The line inside the frontmatter that marks the file as projected. It is a YAML comment, so
        # the frontmatter stays the first block of the file.
        BANNER = "# Generated from agents.bluebook, do not edit"

        # The frontmatter keys a row can say.
        KEYS = %w[name description tools model].freeze

        module_function

        # @param row [Hash] a `RoleFile` row
        # @return [String] the role file
        def text(row)
          [front(row), row[:purpose].to_s, "## How to work\n\n#{row[:steps]}", row[:rules].to_s,
           "## What you hand back\n\n#{row[:handback]}"].reject(&:empty?).join("\n\n").then { |body| "#{body}\n" }
        end

        # @return [String] the frontmatter, closed by a blank line
        def front(row)
          ["---", "name: #{row[:role]}", "description: #{row[:description]}", "tools: #{row[:tools]}",
           "model: #{row[:model]}", BANNER, "---"].join("\n")
        end
      end
    end
  end
end

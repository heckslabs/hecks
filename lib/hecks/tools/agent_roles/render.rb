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

        # The rules section that closes a file, after the handback; the other rules open it.
        CLOSING = "## Handoffs"

        # The start of a `## ` section, where the rules of a row are cut.
        SECTION_START = /^(?=## )/

        module_function

        # @param row [Hash] a `RoleFile` row
        # @return [String] the role file
        def text(row)
          closing, opening = sections(row[:rules]).partition { |section| section.start_with?(CLOSING) }
          [front(row), row[:purpose].to_s, *opening, "## How to work\n\n#{row[:steps]}",
           "## What you hand back\n\n#{row[:handback]}", *closing].reject(&:empty?).join("\n\n").then { |body| "#{body}\n" }
        end

        # @param rules [String, nil] the `rules` of a row, one or more `## ` sections
        # @return [Array<String>] each section, trimmed
        def sections(rules) = rules.to_s.split(SECTION_START).map(&:strip)

        # @return [String] the frontmatter, closed by a blank line
        def front(row)
          ["---", "name: #{row[:role]}", "description: #{row[:description]}", "tools: #{row[:tools]}",
           "model: #{row[:model]}", BANNER, "---"].join("\n")
        end
      end
    end
  end
end

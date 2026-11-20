# frozen_string_literal: true

module Hecks
  module Tools
    module AgentRoles
      # Renders one `RoleFile` row as the text of its role file.
      module Render
        # The line inside the frontmatter that marks the file as projected. It is a YAML comment, so
        # the frontmatter stays the first block of the file.
        BANNER = "# Generated from agents.bluebook, do not edit"

        # The frontmatter keys a row can say; `mcpServers` comes from the role's `RoleServer` rows.
        KEYS = %w[name description tools model mcpServers].freeze

        # The rules section that closes a file, after the handback; the other rules open it.
        CLOSING = "## Handoffs"

        # The start of a `## ` section, where the rules of a row are cut.
        SECTION_START = /^(?=## )/

        module_function

        # @param row [Hash] a `RoleFile` row, with its `servers`
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
           "model: #{row[:model]}", *servers(row[:servers].to_a), BANNER, "---"].join("\n")
        end

        # @param rows [Array<Hash>] the `RoleServer` rows of a role
        # @return [Array<String>] the `mcpServers` lines, none when the role starts no server
        def servers(rows)
          return [] if rows.empty?

          ["mcpServers:", *rows.flat_map { |server| server_lines(server) }]
        end

        # @param server [Hash] one `RoleServer` row
        # @return [Array<String>] its `mcpServers` entry: a stdio command and its domains
        def server_lines(server)
          ["  - #{server[:server]}:", "      type: stdio", "      command: #{server[:command]}",
           "      env:", "        HECKS_SERVER_DOMAINS: #{server[:domains]}"]
        end
      end
    end
  end
end

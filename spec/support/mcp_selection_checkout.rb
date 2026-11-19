# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"

# A checkout with a `.mcp.json` of two project servers and the coder and architect role files.
module McpSelectionCheckout
  PROJECT = %w[hecks-query-ir hecks-mcp].freeze

  def self.build
    dir = Dir.mktmpdir("mcp-selection")
    File.write(File.join(dir, ".mcp.json"), JSON.generate("mcpServers" => PROJECT.to_h { |name| [name, {}] }))
    role(dir, "coder", "tools: Read, Edit, Write, Grep, Glob, Bash")
    role(dir, "architect", "tools: Read, Grep, Glob, mcp__hecks\nmcpServers:\n  - hecks:\n      type: stdio")
    dir
  end

  def self.role(dir, name, frontmatter)
    FileUtils.mkdir_p(File.join(dir, ".claude", "agents"))
    File.write(File.join(dir, ".claude", "agents", "#{name}.md"), "---\nname: #{name}\n#{frontmatter}\n---\n\nbody\n")
  end
end

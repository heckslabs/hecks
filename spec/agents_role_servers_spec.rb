require "spec_helper"
require "hecks/hecks/adapters/mcp_selection"

# The rows of the Role aggregate that say what a role's session starts: its `RoleFile` tools and
# its `RoleServer` rows, read from the Agents bluebook.
module RoleServerRows
  ROOT = InMemoryDomain::ROOT

  def role_table(name)
    bluebook = Hecks.describe(File.join(ROOT, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    role = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == name }.members
  end

  def tools_of(row) = row[:tools].split(",").map(&:strip)

  # @return [Array<String>] the servers a tools line names, as `mcp__<server>` or
  #   `mcp__<server>__<tool>`
  def named_servers(row)
    tools_of(row).filter_map { |tool| tool[/\Amcp__(.+?)(?:__.+)?\z/, 1] }.uniq
  end

  def own_servers(role) = role_table("RoleServer").select { |row| row[:role] == role }.map { |row| row[:server] }

  def project_servers = JSON.parse(File.read(File.join(ROOT, ".mcp.json"))).fetch("mcpServers").keys

  # @return [Array<String>] the servers the role's session starts: its own rows, and the
  #   `.mcp.json` servers McpSelection keeps for it
  def started(role)
    own_servers(role) + (project_servers - Hecks::Adapters::McpSelection.new(ROOT, role).disabled)
  end

  def server_roles = role_table("RoleFile").reject { |row| named_servers(row).empty? }
end

# A role whose brief uses an MCP server's tools starts that server, can wait for it to connect, and
# reads without it once it has failed twice.
RSpec.describe "the Role aggregate's RoleServer rows" do
  include RoleServerRows

  it "start every server a role's tools name" do
    missing = server_roles.flat_map { |row| named_servers(row).map { |s| [row[:role], s] } }
    expect(missing.reject { |role, server| started(role).include?(server) }).to be_empty
  end

  it "go with ToolSearch, so a session waits for a server still connecting" do
    expect(server_roles.reject { |row| tools_of(row).include?("ToolSearch") }.map { |row| row[:role] }).to be_empty
  end

  it "go with Bash, the way a session reads once its server has failed twice" do
    expect(server_roles.reject { |row| tools_of(row).include?("Bash") }.map { |row| row[:role] }).to be_empty
  end

  it "say to call a failed tool once more before reading without the server" do
    expect(server_roles.reject { |row| row[:steps].include?("is called once more") }).to be_empty
  end

  it "say a review ends with its verdict whatever the server does" do
    expect(server_roles.reject { |row| row[:steps].include?("never end a review without its Verdict line") }).to be_empty
  end

  it "name only servers their role's tools use" do
    tools = role_table("RoleFile").to_h { |row| [row[:role], row] }
    expect(role_table("RoleServer").reject { |row| named_servers(tools.fetch(row[:role])).include?(row[:server]) }).to be_empty
  end

  it "give the architect its hecks server" do
    expect(started("architect")).to include("hecks")
  end
end

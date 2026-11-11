require "spec_helper"

# The agent files under `.claude/agents`, cut into the slices a `RoleFile` row carries.
module RoleFileSlices
  AGENTS = File.join(InMemoryDomain::ROOT, ".claude/agents")
  HEADING = /\A## (How to work|What you hand back|What to return)/

  def rows
    bluebook = Hecks.describe(File.join(InMemoryDomain::ROOT, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    role = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == "RoleFile" }.members.to_h { |row| [row[:role], row] }
  end

  def world_roles
    world = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks/hecks.world"))
    world[/agent_roles "PipelineBoard", roles: "([^"]*)"/, 1].split(",")
  end

  def slices(name)
    _, front, body = File.read(File.join(AGENTS, "#{name}.md")).split(/^---\n/, 3)
    sections = body.sub(/\A\n+/, "").split(/^(?=## )/)
    { front: front, purpose: sections.shift.strip, sections: sections }
  end

  def front(slice, key) = slice[:front][/^#{key}: (.*)$/, 1]
  def body_of(section) = section.sub(/\A## [^\n]*\n+/, "").strip
  def steps_of(slice) = body_of(slice[:sections].find { |s| s.start_with?("## How to work") })

  def handback_of(slice)
    body_of(slice[:sections].find { |s| s.match?(/\A## What (you hand back|to return)/) })
  end

  def head_of(slice)
    { description: front(slice, "description"), tools: front(slice, "tools"),
      model: front(slice, "model"), purpose: slice[:purpose] }
  end

  def body_slices(slice)
    { steps: steps_of(slice), rules: rules_of(slice), handback: handback_of(slice) }
  end

  def rules_of(slice)
    slice[:sections].grep_v(HEADING).map(&:strip).join("\n\n")
  end
end

# Every existing agent file is a `RoleFile` row of the Role aggregate, word for word, and the
# rows name the same roles as the world's `agent_roles` line.
RSpec.describe "the Role aggregate's RoleFile rows" do
  include RoleFileSlices

  it "loads one row for each role the world pins" do
    expect(rows.keys).to match_array(world_roles)
  end

  %w[planner orchestrator architect coder reviewer release_manager pruner].each do |name|
    it "holds the head of #{name} word for word" do
      expect(rows.fetch(name).slice(:description, :tools, :model, :purpose)).to eq(head_of(slices(name)))
    end

    it "holds the body of #{name} word for word" do
      expect(rows.fetch(name).slice(:steps, :rules, :handback)).to eq(body_slices(slices(name)))
    end
  end
end

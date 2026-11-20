require "spec_helper"
require "hecks/agents/adapters/routing_guard"

# The architect's row of the Agents bluebook's Role aggregate, and the Bash commands its steps and
# rules tell it to run once its hecks server has closed mid-review.
module ArchitectFallback
  ROOT = InMemoryDomain::ROOT

  def architect_row
    bluebook = Hecks.describe(File.join(ROOT, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    role = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == "RoleFile" }.members.find { |row| row[:role] == "architect" }
  end

  # @return [Array<String>] each `exe/hecks` or `git` command the row quotes, its `<placeholder>`
  #   words filled in as a session would
  def fallback_reads
    quoted = "#{architect_row[:steps]} #{architect_row[:rules]}".scan(%r{`((?:exe/hecks|git) [^`]+)`}).flatten
    quoted.map { |command| command.gsub(/<[^>]+>/, "abc123") }
  end

  def allowed?(command)
    Hecks::Adapters::RoutingGuard.new.guard(role: { value: "architect" }, command: { value: command })[:text] == "allowed"
  rescue Hecks::Adapters::RoutingGuard::Refused
    false
  end
end

# An architect whose hecks server timed out or closed reads through Bash, and the routing guard
# holds that Bash to the reads its row names.
RSpec.describe "the architect without its hecks server" do
  include ArchitectFallback

  it "is told the model check, the change review's diff and git's diff as Bash reads", :aggregate_failures do
    expect(fallback_reads.grep(/ModelCheckRun\.model_check!/)).not_to be_empty
    expect(fallback_reads.grep(/ChangeReview\.diff/)).not_to be_empty
    expect(fallback_reads.grep(/\Agit diff main\.\.\./)).not_to be_empty
  end

  it "may run every Bash read its steps and rules name" do
    expect(fallback_reads.reject { |command| allowed?(command) }).to be_empty
  end

  it "may read a commit with git show and git log", :aggregate_failures do
    expect(allowed?("git show abc123 --stat")).to be(true)
    expect(allowed?("git log -3 main")).to be(true)
  end

  it "may not write through git or the launcher", :aggregate_failures do
    expect(allowed?("git commit -m x")).to be(false)
    expect(allowed?("git push origin main")).to be(false)
    expect(allowed?("exe/hecks tickets Work.plan! title.value=x")).to be(false)
  end

  it "may not have git write a file or run a program", :aggregate_failures do
    expect(allowed?("git diff --output=x main...abc123")).to be(false)
    expect(allowed?("git diff --ext-diff main...abc123")).to be(false)
  end

  it "is not told a git call its rows refuse" do
    expect(allowed?("git -C /primary diff main...abc123")).to be(false)
  end
end

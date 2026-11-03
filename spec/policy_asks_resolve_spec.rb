require "spec_helper"

# Every policy in every bluebook the walk boots: an `ask` resolves to one port operation a
# hecksagon declared, and a `trigger` names a command or query its target domain declares.
# A policy that breaks either fails here, at the commit that breaks it, instead of refusing
# every event at run time.
RSpec.describe "every policy's ask and trigger" do
  # Bluebook directories the walk leaves out, with the reason each one is left out.
  WALK_SKIPS = {
    "lib/hecks/catcher"        => "its boot opens the live ledger, which no spec may do",
    "lib/hecks/forms/examples" => "an example that needs Hecks::Forms configured, not a domain"
  }.freeze

  before(:all) do
    @registries = [File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), *standalone_dirs]
                  .map { |dir| InMemoryDomain.boot_hecks_in_memory(dir).registry }
  end

  let(:registries) { @registries }

  # The bluebook directories that boot on their own. The Hecks domain's own subdirectories
  # are part of the Hecks boot, so they are left to it.
  def standalone_dirs
    hecks_root = File.join(InMemoryDomain::ROOT, "lib/hecks/hecks/")
    Dir.glob(File.join(InMemoryDomain::ROOT, "lib/**/*.bluebook"))
       .map { |file| File.dirname(file) }.uniq.sort
       .reject { |dir| dir.start_with?(hecks_root) || walk_skipped?(dir) }
  end

  def walk_skipped?(dir) = WALK_SKIPS.key?(dir.delete_prefix("#{InMemoryDomain::ROOT}/"))

  # Every problem one registry's policies have, each named by its policy and the reason.
  def problems(registry)
    registry.bluebooks.values.flat_map do |declaration|
      declaration.policies.filter_map { |policy| problem(registry, declaration, policy) }
    end
  end

  def problem(registry, declaration, policy)
    return unresolved_ask(declaration, policy) if policy.asks?

    unnamed_trigger(registry, declaration, policy)
  end

  # An ask resolves through the declaration's own aggregates and the ports their hecksagons
  # declare, so a resolved verb names an operation reachable from the policy's domain.
  def unresolved_ask(declaration, policy)
    outcome = Hecks::Bluebook::AskResolution.call(declaration, policy)
    "#{declaration.hecks_name}.#{policy.hecks_name}: #{outcome.detail}" unless outcome.resolved?
  end

  def unnamed_trigger(registry, declaration, policy)
    target = policy.target_domain || declaration.hecks_name
    return if declares?(registry, target, policy.trigger_command)

    "#{declaration.hecks_name}.#{policy.hecks_name}: " \
      "trigger #{policy.trigger_command} is not declared by #{target}"
  end

  # Whether `domain` declares a command or query `verb` (`Aggregate.Operation`).
  def declares?(registry, domain, verb)
    aggregate_name, operation = verb.to_s.split(".", 2)
    aggregate = registry.bluebook(domain)&.aggregates&.find do |candidate|
      candidate.hecks_name == aggregate_name
    end
    return false unless aggregate

    (aggregate.commands + aggregate.queries).any? { |item| item.hecks_name == operation }
  end

  def resolved(domain, name)
    declaration = registries.first.bluebook(domain)
    policy = declaration.policies.find { |candidate| candidate.hecks_name == name }
    Hecks::Bluebook::AskResolution.call(declaration, policy).verb
  end

  it "finds no ask or trigger that its domain does not declare, in any walked bluebook" do
    expect(registries.flat_map { |registry| problems(registry) }).to eq([])
  end

  it "finds a declared command for a trigger, so the check above is not vacuous" do
    expect(declares?(registries.first, "Hecks", "Dispatch.Record")).to be(true)
  end

  it "finds no command for a verb the domain does not declare" do
    expect(declares?(registries.first, "Hecks", "Dispatch.NoSuchCommand")).to be(false)
  end

  it "resolves ChooseWhenFilling to the Dispatching port's Choose" do
    expect(resolved("Hecks", "ChooseWhenFilling")).to eq("Dispatch::Dispatching.Choose")
  end

  it "resolves OpenIssueWhenRunReported to the GitHubIssues port's OpenIssue" do
    expect(resolved("Tickets", "OpenIssueWhenRunReported")).to eq("Finding::GitHubIssues.OpenIssue")
  end
end

require "hecks/agents/adapters/routing_guard"

# The commands each guarded role is told to run, read from the bluebooks: its `RoleFile`
# text, every policy brief written for it, and every `StallKind` move it fixes. A backticked
# `exe/hecks`, `git` or `gh` span is a command the role runs, so a text that names one for
# another role (the words an orchestrator writes into a coder's brief) leaves the `exe/hecks`
# prefix off. A move has no backticks: its bare `Aggregate.verb` words and its parenthesised
# `git`/`gh` calls are its commands.
module BriefCommands
  ROOT = InMemoryDomain::ROOT
  SPAN = %r{`((?:exe/hecks|git|gh) [^`]+)`}
  VERB = %r{(?<![`\w/.])([A-Z]\w+\.[a-z_]+!?)(?=[\s,.;:)']|\z)}
  SHELL = /\(((?:git|gh) [^)]+)\)/

  # @return [Array<Array(String, String, String)>] role, source, command: each command a guarded
  #   role's texts name that its routing guard refuses
  def refused = commands.reject { |role, _, command| allowed?(role, command) }

  # @return [Array<Array(String, String, String)>] role, source, command for every guarded role
  def commands
    texts.flat_map { |role, source, text| named(text, move: source.start_with?("move")).map { |c| [role, source, c] } }
         .select { |role, _, _| guarded.include?(role) }.uniq
  end

  # @param role [String] a role
  # @param command [String] a command, its placeholders filled
  # @return [Boolean] whether the role's guard lets it run
  def allowed?(role, command)
    guard.guard(role: { value: role }, command: { value: command }) == { text: "allowed" }
  rescue Hecks::Adapters::RoutingGuard::Refused
    false
  end

  # @return [Array<String>] the roles with routing rows
  def guarded = (@guarded ||= members(agents, "Role", "RoutingRule").map { |row| row[:role] }.uniq)

  # @param text [String] a brief, a role file slice or a move
  # @param move [Boolean] whether the text is a move, which names its commands bare
  # @return [Array<String>] each command it names, `<placeholder>` filled and a trailing `...` cut
  def named(text, move: false)
    found = text.scan(SPAN).flatten
    found += bare(text) if move
    found.map { |command| command.gsub(/<[^>]*>/, "x").sub(/\s+\.\.\.\z/, "").strip }.uniq
  end

  # The stall wake is the Hecks domain's translation of its own `StallFiled` into Agents' command.
  #
  # @return [Object] what the stall wake passes as its brief: a `StallFiled` field, not a sentence
  def stall_wake_brief
    hecks.policies.find { |policy| policy.name == "WakeWhenAStallIsFiled" }.with_spec.to_h.transform_keys(&:to_s)["brief"]
  end

  private

  def bare(text)
    text.scan(VERB).flatten.map { |verb| "exe/hecks #{verb}" } + text.scan(SHELL).flatten.flat_map { |call| call.split(", ") }
  end

  def guard = (@guard ||= Hecks::Adapters::RoutingGuard.new)

  def texts = role_files + briefs + moves

  def role_files
    members(agents, "Role", "RoleFile").flat_map do |row|
      %i[steps rules handback].map { |slice| [row[:role], "RoleFile #{row[:role]}.#{slice}", row[slice].to_s] }
    end
  end

  def moves
    members(hecks, "StallWatch", "StallKind").map { |row| [row[:fixer], "move #{row[:kind]}", row[:move].to_s] }
  end

  # The policies whose `with:` holds a written brief and names its role (`agent:` or `role:`).
  def briefs
    [agents, hecks].flat_map(&:policies).filter_map do |policy|
      with = policy.with_spec.to_h.transform_keys(&:to_s)
      next unless with["brief"].is_a?(String)

      [with.fetch("agent") { with["role"] }.to_s, "policy #{policy.name}", with["brief"]]
    end
  end

  def members(bluebook, aggregate, table)
    bluebook.aggregates.find { |candidate| candidate.hecks_name == aggregate }
            .value_objects.find { |object| object.hecks_name == table }.members
  end

  def agents = (@agents ||= described("lib/hecks/agents", "Agents"))

  def hecks = (@hecks ||= described("lib/hecks/hecks", "Hecks"))

  def described(dir, name) = Hecks.describe(File.join(ROOT, dir)).registry.bluebooks.fetch(name)
end

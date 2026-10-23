require "hecks/projections"
require "hecks/forms"

# What one domain names, and how each projection of it reads, for checking that the projections
# leave nothing out. Every name is held in the projection's own wording: a statement says
# "adding a topping", a glossary entry is keyed by the command's name, a diagram and a form use
# the declared names as written.
class DomainNames
  PLAIN = Hecks::Projections::PlainEnglish

  def initialize(dir)
    @registry = Hecks::Runtime::Loader.describe(dir, environment: nil).registry
    @chapter  = @registry.bluebooks.values.first
  end

  # @return [Hash{Symbol => Array<Array(String, String)>}] each kind's `[declared, plain]` names
  def names = { actions: actions, rules: rules, stages: stages, roles: roles }

  # @return [String] the projection's text, or its glossary entry names one per line
  def text(projection) = public_send(:"#{projection}_text")

  def statements_text = Hecks::Projector.call(:statements, bluebook: @chapter, options: {}).join("\n").downcase

  def glossary_text
    entries = Hecks::Projections::Glossary::Entries.all(@chapter).map(&:name)
    [*entries, Hecks::Projector.call(:glossary, bluebook: @chapter, options: {})["glossary.md"]].join("\n")
  end

  def diagrams_text = Hecks::Projector.call(:diagrams, bluebook: @chapter, options: {}).values.join("\n")

  # The form of every aggregate command; the forms app serves no entity command.
  def forms_text
    @chapter.aggregates.flat_map do |aggregate|
      aggregate.commands.map do |command|
        Hecks::Forms::CommandFormRenderer.render(registry: @registry, domain: @chapter.name, aggregate: aggregate,
                                                 command: command, action: "/#{@chapter.name}")
      end
    end.join("\n")
  end

  # The names of `kind` that `projection` leaves out: neither declared nor plain name appears.
  def missing(kind, projection, among: names.fetch(kind))
    projected = text(projection)
    among.reject { |declared, plain| projected.include?(declared) || projected.downcase.include?(plain) }.map(&:first)
  end

  # The `[holder, command]` pairs `scope` covers: `:all`, or `:aggregate` for aggregates only.
  def commands(scope = :all)
    holders = scope == :aggregate ? @chapter.aggregates : @chapter.aggregates.flat_map { |a| [a, *a.entities] }
    holders.flat_map { |holder| holder.commands.map { |command| [holder, command] } }
  end

  def actions(scope = :all) = commands(scope).map { |h, c| [c.hecks_name, PLAIN.doing(c.hecks_name, h.hecks_name).downcase] }.uniq

  def rules(scope = :all) = commands(scope).flat_map { |_, c| c.givens.map { |g| [g.description, g.description.downcase] } }.uniq

  def roles(scope = :all)
    commands(scope).filter_map { |_, c| c.role&.to_s }.reject(&:empty?).uniq.map { |r| [r, PLAIN.noun(r).downcase] }
  end

  def stages
    lifecycles = @chapter.aggregates.flat_map { |a| [a, *a.entities] }.filter_map(&:lifecycle)
    states = lifecycles.flat_map { |lifecycle| [lifecycle.default, *lifecycle.transitions.map { |_, move| move.target }] }
    states.compact.uniq.map { |state| [state.to_s, PLAIN.state(state)] }
  end

  # The actions a statement speaks of: those with a role, a rule or a lifecycle move to state.
  def stated_actions
    commands.select { |holder, command| command.role || command.givens.any? || moves?(holder, command) }
            .map { |h, c| [c.hecks_name, PLAIN.doing(c.hecks_name, h.hecks_name).downcase] }.uniq
  end

  def moves?(holder, command) = holder.lifecycle&.transitions&.any? { |name, _| name.to_s == command.hecks_name }
end

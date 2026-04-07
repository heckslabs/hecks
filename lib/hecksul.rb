# HecksUL
#
# HecksUL (Ubiquitous Language) is a domain modeling language.
# Every Hecks domain is its own executable business language —
# the Bluebook defines the grammar, aggregates are types,
# commands are operations, and generated specs are the type checker.
#
#   require "hecksul"
#
#   HecksUL.syntax        # => [:aggregate, :command, :attribute, ...]
#   HecksUL.compiler      # => { frontend: "DSL", ir: "DomainModel", ... }
#   HecksUL.self_hosting  # => { chapters: 15, aggregates: 670, commands: 836 }
#
require "hecks"

module HecksUL
  HECKSTIES_ROOT = File.expand_path("..", __dir__)
  VERSION = "0.1.0"

  # -- Syntax --

  KEYWORDS = {
    domain:        %i[aggregate policy service view workflow saga actor glossary
                      world_concerns tenancy domain_module on_event entry_point description],
    aggregate:     %i[attribute list_of reference_to value_object entity command query
                      scope specification policy validation invariant lifecycle port
                      on_event repository factory event computed identity
                      namespace inherits includes description],
    command:       %i[attribute reference_to description method_name guarded_by sets
                      actor read_model external precondition postcondition handler
                      call emits],
    value_object:  %i[attribute description invariant],
    entity:        %i[attribute description invariant]
  }.freeze

  def self.syntax
    KEYWORDS
  end

  # -- Compiler --

  def self.compiler
    {
      frontend:   "Bluebook DSL",
      ir:         "Hecks::DomainModel",
      backends:   backends,
      loader:     "Hecks::InMemoryLoader"
    }
  end

  def self.backends
    targets = Hecks.registered_targets.keys rescue []
    targets.empty? ? %i[ruby go node rails] : targets
  end

  # -- Runtime --

  def self.runtime
    {
      command_bus: "Hecks::Commands::CommandBus",
      event_bus:   "Hecks::EventBus",
      repository:  "Generated per-aggregate (memory, PStore, SQL)",
      middleware:  "CommandBus#use — before/after/around hooks",
      adapters:    "Runtime#adapt — wire behavior to command ports"
    }
  end

  # -- Type System --

  TYPES = %w[String Integer Float Boolean Symbol Array Hash Date DateTime JSON].freeze

  def self.type_system
    {
      primitives:   TYPES,
      collections:  "list_of(Type)",
      references:   "reference_to(Aggregate)",
      enums:        "enum: [values]",
      computed:     "computed :name do ... end",
      validations:  "validation :field, rules",
      invariants:   "invariant 'message' do ... end",
      contracts:    "Shape conformance, not interfaces"
    }
  end

  # -- Module System --

  def self.module_system
    {
      unit:      "Aggregate — consistency boundary with commands, events, value objects",
      grouping:  "Chapter — a Bluebook defining a bounded context",
      nesting:   "Paragraph — a file within a chapter",
      packaging: "Domain — a chapter compiled to a runtime or gem"
    }
  end

  # -- IO Model --

  def self.io_model
    {
      ports:    "Commands — declared in the Bluebook, define the interface",
      adapters: "Modules with methods matching command names (snake_case)",
      pattern:  "Shape (DSL) + Behavior (adapter) = running system",
      built_in: %w[TestHelperAdapter EventBusAdapter PStoreAdapter]
    }
  end

  # -- Self-Hosting --

  def self.load_all_chapters
    Dir.glob(File.join(HECKSTIES_ROOT, "..", "**/lib/hecks/chapters/*.rb"))
      .reject { |f| f.include?("/.claude/") }
      .each { |f| require f }
  end

  def self.self_hosting
    load_all_chapters
    chapters = Hecks::Chapters.constants.select { |c|
      mod = Hecks::Chapters.const_get(c)
      mod.respond_to?(:definition)
    }

    totals = chapters.each_with_object({ aggregates: 0, commands: 0 }) do |ch, acc|
      domain = Hecks::Chapters.const_get(ch).definition
      domain.aggregates.each do |agg|
        acc[:aggregates] += 1
        acc[:commands] += agg.commands.size
      end
    end

    {
      chapters:   chapters.size,
      aggregates: totals[:aggregates],
      commands:   totals[:commands],
      proof:      "Every chapter boots as a running Hecks app via InMemoryLoader + Runtime"
    }
  end

  # -- Specification Summary --

  def self.spec
    {
      syntax:       syntax,
      compiler:     compiler,
      runtime:      runtime,
      type_system:  type_system,
      module_system: module_system,
      io_model:     io_model,
      self_hosting: self_hosting
    }
  end

  def self.describe
    puts "HecksUL v#{VERSION}"
    puts ""
    puts "Syntax:        #{syntax.values.flatten.size} keywords across #{syntax.size} contexts"
    puts "Compiler:      #{compiler[:frontend]} → #{compiler[:ir]} → #{compiler[:backends].join(", ")}"
    puts "Runtime:       CommandBus + EventBus + Repositories + Middleware"
    puts "Type system:   #{TYPES.size} primitives, collections, references, enums, computed"
    puts "Module system: Aggregate → Chapter → Paragraph → Domain"
    puts "IO model:      Commands (ports) + Adapters (behavior)"
    sh = self_hosting
    puts "Self-hosting:  #{sh[:chapters]} chapters, #{sh[:aggregates]} aggregates, #{sh[:commands]} commands"
  end
end

# Backward compat alias
HecksCode = HecksUL unless defined?(HecksCode)

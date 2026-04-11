require "json"
require "date"
require "ostruct"

JSON::Validator.use_multi_json = false if defined?(JSON::Validator)

# Bootstrap — must load before chapter system (errors, naming, autoloads,
# registries). These define the module infrastructure that Chapters and
# BluebookBuilder depend on, so they cannot be chapter-driven.
require "hecks/errors"
require "hecks/conventions"
require "hecks/autoloads"

# Module infrastructure — DSL, registries, discovery
require "hecks/registry"
require "hecks/set_registry"
require "hecks/module_dsl"
require "hecks/core_extensions"
require "hecks/registries/extension_registry"
require "hecks/registries/capability_registry"
require "hecks/registries/bluebook_registry"
require "hecks/bluebook/event_storm_importer"
require "hecks/registries/cross_domain"
require "hecks/registries/thread_context"
require "hecks/registries/target_registry"
require "hecks/registries/adapter_registry"
require "hecks/registries/validation_registry"
require "hecks/registries/dump_format_registry"
require "hecks/registries/grammar_registry"

# Extend registry methods early — Bluebook's chapter loading needs them
module Hecks
  extend ExtensionRegistryMethods
  extend CapabilityRegistryMethods
  extend BluebookRegistryMethods
  extend CrossDomainMethods
  extend ThreadContextMethods
  extend TargetRegistryMethods
  extend AdapterRegistryMethods
  extend ValidationRegistryMethods
  extend DumpFormatRegistryMethods
  extend GrammarRegistryMethods
end

# Chapter infrastructure — Chapters module defines require_paragraphs,
# load_chapter, etc. needed by all chapter registrations.
require "hecks/chapters"

# Chapter selection — register all available chapters, then load
require "hecks/chapter_loader"
require "hecks/chapters/registry"

# Load chapters from HecksChapters file if present, otherwise load all.
# HecksChapters is a simple DSL file listing which chapters to include:
#
#   # HecksChapters
#   chapter :bluebook
#   chapter :runtime
#   chapter :hecksagon
#
# When no HecksChapters file exists, all chapters are loaded (default).
Hecks::ChapterLoader.load_from_file || Hecks.chapters(:all)

require "hecks/bluebook/inspector"
require "hecks/bluebook/builder_methods"
require "hecks/bluebook/compiler"
require "hecks/bluebook/visualizer_methods"
require "hecks/bluebook/connections"
require "hecks/registries/bluebook_registry"
require "hecks/bluebook/event_storm_importer"

module Hecks
  # Thread-local role for command authorization.
  # Set before dispatching role-restricted commands:
  #   Hecks.current_role = "Customer"
  def self.current_role
    Thread.current[:_hecks_current_role]
  end

  def self.current_role=(role)
    Thread.current[:_hecks_current_role] = role
  end

  extend BluebookInspector
  extend BluebookBuilderMethods
  extend BluebookCompiler
  extend EventStormImporter
  extend BluebookVisualizerMethods
  extend Boot
  extend BootBluebook

  def self.configure(&block)
    @configuration = Configuration.new
    @configuration.instance_eval(&block)
    @configuration.boot! unless defined?(::Rails)
    @configuration
  end

  def self.configuration
    @configuration
  end

  # Load a domain from an IR object and return a booted Runtime. No filesystem
  # required -- uses InMemoryLoader to generate and eval source in memory.
  #
  #   runtime = Hecks.load(domain)
  #   runtime = Hecks.load(domain, event_bus: my_bus)
  #
  # @param domain [Hecks::BluebookModel::Structure::Domain] the domain IR
  # @param force [Boolean] reload even if already cached (default false)
  # @param opts [Hash] extra options forwarded to Runtime (e.g. event_bus:)
  # @return [Hecks::Runtime] a fully wired runtime with memory adapters
  def self.load(domain, force: false, **opts, &config)
    load_bluebook(domain, force: force)
    Runtime.new(domain, **opts, &config)
  end

  # Core build target — always available
  register_target(:ruby) { |domain, **opts| Hecks.build(domain, **opts) }

  # Binary target — compiles Hecks into a single bundled script
  register_target(:binary) { |_domain, **opts|
    require "hecks/compiler"
    Hecks::Compiler::BinaryCompiler.new.compile(output: opts[:output] || "hecks_v0")
  }

  # Other targets (go, static, node, rails) self-register
  # when their chapters are loaded. See hecks_targets/ for each.

  # Built-in dump formats
  register_dump_format(:schema, desc: "JSON Schema") { |domain, say:| require "hecks_serve"; File.write("schema.json", JSON.pretty_generate(Hecks::HTTP::JsonSchemaGenerator.new(domain).generate)); say.call("Dumped schema.json", :green) }
  register_dump_format(:swagger, desc: "OpenAPI 3.0") { |domain, say:| require "hecks_serve"; File.write("openapi.json", JSON.pretty_generate(Hecks::HTTP::OpenapiGenerator.new(domain).generate)); say.call("Dumped openapi.json", :green) }
  register_dump_format(:rpc, desc: "JSON-RPC discovery") { |domain, say:| require "hecks_serve"; File.write("rpc_methods.json", JSON.pretty_generate(Hecks::HTTP::RpcDiscovery.new(domain).generate)); say.call("Dumped rpc_methods.json", :green) }
  register_dump_format(:domain, desc: "domain gem") { |domain, say:| FileUtils.mkdir_p("domain"); say.call("Dumped domain gem to domain/#{File.basename(Hecks.build(domain, output_dir: "domain"))}/", :green) }
  register_dump_format(:glossary, desc: "plain-English glossary") { |domain, say:| File.write("glossary.md", Hecks::BluebookGlossary.new(domain).generate.join("\n") + "\n"); say.call("Dumped glossary.md", :green) }
  register_dump_format(:types, desc: "TypeScript types (.d.ts)") { |domain, say:| File.write("types.d.ts", Hecks::HTTP::TypescriptGenerator.new(domain).generate); say.call("Dumped types.d.ts", :green) }
end

require "json"
require "date"
require "ostruct"

JSON::Validator.use_multi_json = false if defined?(JSON::Validator)

require_relative "hecks/errors"
require_relative "hecks/conventions"
require_relative "hecks/autoloads"

# Module infrastructure — DSL, registries, discovery
require_relative "hecks/registry"
require_relative "hecks/set_registry"
require_relative "hecks/module_dsl"
require_relative "hecks/core_extensions"
require_relative "hecks/registries/extension_registry"
require_relative "hecks/registries/capability_registry"
require_relative "hecks/registries/domain_registry"
require_relative "hecks/registries/cross_domain"
require_relative "hecks/registries/thread_context"
require_relative "hecks/registries/target_registry"
require_relative "hecks/registries/adapter_registry"
require_relative "hecks/registries/validation_registry"
require_relative "hecks/registries/dump_format_registry"
require_relative "hecks/registries/grammar_registry"

# Extend registry methods early — Bluebook's chapter loading needs them
module Hecks
  extend ExtensionRegistryMethods
  extend CapabilityRegistryMethods
  extend DomainRegistryMethods
  extend CrossDomainMethods
  extend ThreadContextMethods
  extend TargetRegistryMethods
  extend AdapterRegistryMethods
  extend ValidationRegistryMethods
  extend DumpFormatRegistryMethods
  extend GrammarRegistryMethods
end

# Default modules — loaded with require "hecks"
# Bluebook loads its implementation files from its chapter definition
require "bluebook"
require "hecksagon"
require_relative "hecks/stats"
require_relative "hecks/event_sourcing"
require "hecks/runtime/boot"
require_relative "hecks/deprecations"
require "hecks/runtime/boot_bluebook"
require "hecks/workshop"

# Load Bluebook implementation files from its chapter definition.
# Registry methods are already extended above, so validators can register.
Hecks::Chapters.load_chapter(
  Hecks::Chapters::Bluebook,
  base_dir: File.expand_path("../../bluebook/lib", __dir__)
)

# = Hecks
#
# Top-level entry point. Modules load lazily — require only what you use.
#
# Hecks
#
# Top-level framework module: DSL entry point, registry methods, and configuration for all domain components.
#
module Hecks
  extend DomainInspector
  extend BluebookBuilderMethods
  extend BluebookCompiler
  extend EventStormImporter
  extend DomainVisualizerMethods
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
    load_domain(domain, force: force)
    Runtime.new(domain, **opts, &config)
  end

  # Core build target — always available
  register_target(:ruby) { |domain, **opts| Hecks.build(domain, **opts) }

  # Other targets (go, static, node, rails, binary) self-register
  # when their gems are required. See hecks_targets/ for each.

  # Built-in dump formats
  register_dump_format(:schema, desc: "JSON Schema") { |domain, say:| require "hecks_serve"; File.write("schema.json", JSON.pretty_generate(Hecks::HTTP::JsonSchemaGenerator.new(domain).generate)); say.call("Dumped schema.json", :green) }
  register_dump_format(:swagger, desc: "OpenAPI 3.0") { |domain, say:| require "hecks_serve"; File.write("openapi.json", JSON.pretty_generate(Hecks::HTTP::OpenapiGenerator.new(domain).generate)); say.call("Dumped openapi.json", :green) }
  register_dump_format(:rpc, desc: "JSON-RPC discovery") { |domain, say:| require "hecks_serve"; File.write("rpc_methods.json", JSON.pretty_generate(Hecks::HTTP::RpcDiscovery.new(domain).generate)); say.call("Dumped rpc_methods.json", :green) }
  register_dump_format(:domain, desc: "domain gem") { |domain, say:| FileUtils.mkdir_p("domain"); say.call("Dumped domain gem to domain/#{File.basename(Hecks.build(domain, output_dir: "domain"))}/", :green) }
  register_dump_format(:glossary, desc: "plain-English glossary") { |domain, say:| File.write("glossary.md", Hecks::DomainGlossary.new(domain).generate.join("\n") + "\n"); say.call("Dumped glossary.md", :green) }
  register_dump_format(:types, desc: "TypeScript types (.d.ts)") { |domain, say:| File.write("types.d.ts", Hecks::HTTP::TypescriptGenerator.new(domain).generate); say.call("Dumped types.d.ts", :green) }

  if defined?(::Rails::Railtie)
    begin
      require "active_hecks/railtie"
    rescue LoadError
    end
  end
end

# Features (vertical slices) — loaded after Hecks module is fully defined
require "hecks/features"

# Sub-gems load lazily — only when required
# require "hecks_multidomain"  # loads multi-domain support
# require "hecks_explorer"     # loads web explorer
# require "hecks_ai"           # loads MCP server

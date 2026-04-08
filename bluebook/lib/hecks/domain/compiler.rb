require "tmpdir"
  # Hecks::BluebookCompiler
  #
  # Generates domain gems (build) and loads domains into memory (load_domain).
  # By default, load_domain uses InMemoryLoader to compile generated source
  # strings directly via RubyVM without disk I/O. The build method writes a
  # full gem to disk with documentation artifacts (OpenAPI, RPC, JSON Schema,
  # glossary).
  #
  # Target-specific build methods (Go, Node, Rails, binary) live in their
  # respective target gems and self-register via Hecks.register_target when
  # required. See hecks_targets/ for implementations.
  #
  #   Hecks.build(domain, version: "2026.03.23.1")
  #   Hecks.load_domain(domain)
  #

module Hecks
  module BluebookCompiler
    include HecksTemplating::NamingHelpers

    # Build a complete domain gem on disk. Validates the domain first, then
    # generates all Ruby source files, specs, and documentation artifacts
    # (OpenAPI JSON, RPC discovery, JSON Schema, glossary markdown).
    #
    # @param domain [Hecks::BluebookModel::Domain] the domain to compile
    # @param version [String] gem version string (default "0.1.0")
    # @param output_dir [String] parent directory for the generated gem (default ".")
    # @return [String] absolute path to the generated gem root directory
    # @raise [Hecks::ValidationError] if domain validation fails
    def build(domain, version: "0.1.0", output_dir: ".")
      valid, errors = validate(domain)
      unless valid
        raise Hecks::ValidationError.for_domain(errors)
      end

      ValidationRules::Naming::ReservedNames.reserved_attr_warnings(domain).each do |w|
        warn "[Hecks] Warning: #{w}"
      end

      generator = Generators::Infrastructure::DomainGemGenerator.new(domain, version: version, output_dir: output_dir)
      gem_path = generator.generate

      docs_dir = File.join(gem_path, "docs")
      FileUtils.mkdir_p(docs_dir)
      File.write(File.join(docs_dir, "openapi.json"), JSON.pretty_generate(HTTP::OpenapiGenerator.new(domain).generate))
      File.write(File.join(docs_dir, "rpc_methods.json"), JSON.pretty_generate(HTTP::RpcDiscovery.new(domain).generate))
      File.write(File.join(docs_dir, "schema.json"), JSON.pretty_generate(HTTP::JsonSchemaGenerator.new(domain).generate))
      File.write(File.join(docs_dir, "glossary.md"), DomainGlossary.new(domain).generate.join("\n") + "\n")
      File.write(File.join(docs_dir, "types.d.ts"), HTTP::TypescriptGenerator.new(domain).generate)

      gem_path
    end

    # Load a domain into memory so its module (e.g., PizzasDomain) becomes
    # available as a Ruby constant. Uses InMemoryLoader to compile generated
    # source without writing to disk. Caches the loaded module by domain
    # object_id to avoid redundant reloads unless +force+ is true.
    #
    # @param domain [Hecks::BluebookModel::Domain] the domain to load
    # @param force [Boolean] reload even if already cached (default false)
    # @param skip_validation [Boolean] skip validation before loading (default false)
    # @return [Module] the loaded domain module constant (e.g., PizzasDomain)
    # @raise [Hecks::ValidationError] if validation fails and skip_validation is false
    # @raise [Hecks::BluebookLoadError] if generated code has syntax or naming errors
    def load_domain(domain, force: false, skip_validation: false)
      mod = bluebook_module_name(domain.name)
      key = domain.object_id
      return Object.const_get(mod) if !force && loaded_domains[mod] == key && Object.const_defined?(mod)

      unless skip_validation
        validator = Validator.new(domain)
        unless validator.valid?
          raise Hecks::ValidationError.for_domain(validator.errors)
        end
      end

      Hecks::Utils.remove_constant(mod.to_sym)
      begin
        InMemoryLoader.load(domain, mod)
      rescue SyntaxError, NameError => e
        raise Hecks::BluebookLoadError, "Failed to load domain '#{domain.name}': #{e.message}"
      end
      loaded_domains[mod] = key
      domain_objects[mod] = domain
      Object.const_get(mod)
    end
  end
end

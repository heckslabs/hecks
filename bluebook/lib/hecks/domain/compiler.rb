require "tmpdir"

module Hecks
  # Hecks::DomainCompiler
  #
  # Generates domain gems (build) and loads domains into memory (load_domain).
  # By default, load_domain uses InMemoryLoader to compile generated source
  # strings directly via RubyVM without disk I/O. The build method writes a
  # full gem to disk with documentation artifacts (OpenAPI, RPC, JSON Schema,
  # glossary).
  #
  # Extended onto the top-level Hecks module alongside DomainBuilderMethods.
  # Tests use InMemoryLoader for speed; production can use file-based loading
  # via the private load_domain_from_files fallback.
  #
  #   Hecks.build(domain, version: "2026.03.23.1")
  #   Hecks.load_domain(domain)
  #
  module DomainCompiler
    include HecksTemplating::NamingHelpers
    # Build a complete domain gem on disk. Validates the domain first, then
    # generates all Ruby source files, specs, and documentation artifacts
    # (OpenAPI JSON, RPC discovery, JSON Schema, glossary markdown).
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to compile
    # @param version [String] gem version string (default "0.1.0"); typically
    #   a CalVer string from Versioner (e.g., "2026.03.23.1")
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

      require_relative "../generators/docs/openapi_generator"
      require_relative "../generators/docs/rpc_discovery"
      require_relative "../generators/docs/json_schema_generator"
      require_relative "../generators/docs/typescript_generator"
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
    # If the domain module already exists and was loaded from the same domain
    # object, returns the cached constant immediately. Otherwise, removes
    # the old constant, regenerates, and loads fresh.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to load
    # @param force [Boolean] reload even if already cached (default false)
    # @param skip_validation [Boolean] skip validation before loading (default false)
    # @return [Module] the loaded domain module constant (e.g., PizzasDomain)
    # @raise [Hecks::ValidationError] if validation fails and skip_validation is false
    # @raise [Hecks::DomainLoadError] if generated code has syntax or naming errors
    def load_domain(domain, force: false, skip_validation: false)
      mod = domain_module_name(domain.name)
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
        raise Hecks::DomainLoadError, "Failed to load domain '#{domain.name}': #{e.message}"
      end
      loaded_domains[mod] = key
      domain_objects[mod] = domain
      Object.const_get(mod)
    end

    # Build a standalone domain gem with zero runtime dependency on hecks.
    # The output includes an inlined runtime/ directory with Model, Command,
    # EventBus, QueryBuilder, etc. namespaced under the domain module.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to compile
    # @param version [String] gem version string (default "0.1.0")
    # @param output_dir [String] parent directory for the generated gem (default ".")
    # @return [String] absolute path to the generated standalone gem root
    # @raise [Hecks::ValidationError] if domain validation fails
    def build_static(domain, version: "0.1.0", output_dir: ".", smoke_test: true)
      valid, errors = validate(domain)
      unless valid
        raise Hecks::ValidationError.for_domain(errors)
      end

      require "hecks_static"
      generator = HecksStatic::GemGenerator.new(domain, version: version, output_dir: output_dir)
      root = generator.generate
      run_ruby_smoke_test(root, domain) if smoke_test
      root
    end

    # Build a Go project from the domain IR. Same DSL, Go output.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to compile
    # @param output_dir [String] parent directory for the generated project
    # @return [String] absolute path to the generated Go project root
    def build_go(domain, output_dir: ".", smoke_test: true)
      valid, errors = validate(domain)
      unless valid
        raise Hecks::ValidationError.for_domain(errors)
      end

      require "go_hecks"
      generator = GoHecks::ProjectGenerator.new(domain, output_dir: output_dir)
      root = generator.generate
      run_smoke_test(root, domain) if smoke_test
      root
    end

    # Build a multi-domain Go project where each bounded context
    # gets its own Go package with shared runtime and combined server.
    #
    # @param domains [Array<Hecks::DomainModel::Domain>] domains to compile
    # @param output_dir [String] parent directory for the generated project
    # @param name [String] project name (default "multi_domain")
    # @return [String] absolute path to the generated Go project root
    def build_go_multi(domains, output_dir: ".", name: "multi_domain")
      domains.each do |domain|
        valid, errors = validate(domain)
        unless valid
          raise Hecks::ValidationError, "Domain '#{domain.name}' validation failed:\n#{errors.map { |e| "  - #{e}" }.join("\n")}"
        end
      end

      require "go_hecks"
      generator = GoHecks::MultiProjectGenerator.new(domains, output_dir: output_dir, name: name)
      generator.generate
    end

    # Build a Node.js/TypeScript project from the domain IR.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to compile
    # @param output_dir [String] parent directory for the generated project
    # @return [String] absolute path to the generated Node project root
    def build_node(domain, output_dir: ".")
      valid, errors = validate(domain)
      unless valid
        raise Hecks::ValidationError.for_domain(errors)
      end

      require "node_hecks"
      generator = NodeHecks::ProjectGenerator.new(domain, output_dir: output_dir)
      generator.generate
    end

    # Generate a bootstrapped Rails app with the domain loaded.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to compile
    # @param output_dir [String] parent directory for the generated Rails app
    # @return [String] path to the generated Rails app root
    def build_rails(domain, output_dir: ".")
      valid, errors = validate(domain)
      unless valid
        raise Hecks::ValidationError.for_domain(errors)
      end

      require "hecks/generators/rails_generator"
      Generators::RailsGenerator.new(domain).generate(output_dir: output_dir)
    end

    private

    # Start, smoke-test, and stop a static Ruby server.
    def run_ruby_smoke_test(root, domain)
      require "hecks_templating"
      name = domain_snake_name(domain.name)
      bin = File.join(root, "bin", name)
      return unless File.exist?(bin)

      port = rand(10_000..60_000)
      pid = spawn(RbConfig.ruby, bin, "serve", port.to_s,
                  out: "/dev/null", err: "/dev/null")
      sleep 2

      smoke = HecksTemplating::SmokeTest.new("http://localhost:#{port}", domain)
      results = smoke.run
      failed = results.count { |r| r.status == :fail }
      raise "Smoke test: #{failed} failures" if failed > 0
    ensure
      Process.kill("TERM", pid) rescue nil if pid
      Process.wait(pid) rescue nil if pid
    end

    # Build, start, smoke-test, and stop a Go server.
    def run_smoke_test(root, domain)
      require "hecks_templating"
      name = domain_snake_name(domain.name)
      cmd_dir = File.join(root, "cmd", name)
      return unless File.directory?(cmd_dir)

      # Build
      system("cd #{root} && go mod tidy && go build ./...") or return

      # Start on a random port
      port = rand(10_000..60_000)
      pid = spawn("cd #{root} && go run ./cmd/#{name}/ #{port}",
                   out: "/dev/null", err: "/dev/null")
      sleep 2

      # Run smoke test
      smoke = HecksTemplating::SmokeTest.new("http://localhost:#{port}", domain)
      results = smoke.run
      failed = results.count { |r| r.status == :fail }
      raise "Smoke test: #{failed} failures" if failed > 0
    ensure
      Process.kill("TERM", pid) rescue nil if pid
      Process.wait(pid) rescue nil if pid
    end

    # Fallback file-based loading strategy. Generates the full gem to a tmpdir,
    # manipulates $LOAD_PATH, and uses Kernel.load to evaluate each file.
    # Not used by default -- InMemoryLoader is preferred for speed.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to load from files
    # @return [void]
    def load_domain_from_files(domain)
      @tmp_roots ||= {}
      gem_name = domain.gem_name
      dir = @tmp_roots[gem_name] ||= Dir.mktmpdir("hecks-")
      gem_dir = File.join(dir, gem_name)
      FileUtils.rm_rf(gem_dir) if Dir.exist?(gem_dir)
      gen = Generators::Infrastructure::DomainGemGenerator.new(domain, version: "0.0.0", output_dir: dir)
      gem_root = gen.generate

      lib_path = File.join(gem_root, "lib")
      $LOAD_PATH.reject! { |p| p.include?("/#{gem_name}/lib") }
      $LOAD_PATH.unshift(lib_path)
      Kernel.load File.join(lib_path, "#{gem_name}.rb")

      gem_lib = File.join(gem_root, "lib", gem_name)
      files = Dir[File.join(gem_lib, "**/*.rb")].sort
      files.reject! { |f| f.include?("/commands/") || f.include?("/queries/") }
      ports, rest = files.partition { |f| f.include?("/ports/") }
      adapters, rest = rest.partition { |f| f.include?("/adapters/") }
      (ports + rest + adapters).each { |f| Kernel.load f }
    end
  end
end

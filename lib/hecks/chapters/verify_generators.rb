# Hecks::Chapters::GeneratorVerifier
#
# Verifies runtime generators produce valid Ruby from domain IR.
# Boots the Pizzas domain, runs each generator, checks output
# for expected module structure and valid syntax.
#
#   Hecks::Chapters::GeneratorVerifier.run
#   Hecks::Chapters::GeneratorVerifier.run(format: :documentation)
#
module Hecks
  module Chapters
    module GeneratorVerifier
      Result = Struct.new(:pass_count, :errors)

      GENERATORS = {
        "RepositoryWiring" => {
          class_name: "RepositoryWiringGenerator",
          method: "setup_repositories",
          module_name: "RepositoryWiring"
        },
        "PortWiring" => {
          class_name: "PortWiringGenerator",
          method: "wire_ports!",
          module_name: "PortWiring"
        },
        "SubscriberWiring" => {
          class_name: "SubscriberWiringGenerator",
          method: "setup_subscribers",
          module_name: "SubscriberWiring"
        },
        "PolicyWiring" => {
          class_name: "PolicyWiringGenerator",
          method: "setup_policies",
          module_name: "PolicyWiring"
        },
        "ServiceWiring" => {
          class_name: "ServiceWiringGenerator",
          method: "setup_services",
          module_name: "ServiceWiring"
        },
        "WorkflowWiring" => {
          class_name: "WorkflowWiringGenerator",
          method: "setup_workflows",
          module_name: "WorkflowWiring"
        },
        "SagaWiring" => {
          class_name: "SagaWiringGenerator",
          method: "setup_sagas",
          module_name: "SagaWiring"
        }
      }.freeze

      def self.run(format: :progress)
        result = Result.new(0, [])
        puts "\e[1mGenerators\e[0m" if format == :documentation

        load_generators
        app = Hecks.boot(File.join(Dir.pwd, "examples/pizzas"))
        domain = app.domain

        verify_orchestrator(result, format, domain)
        GENERATORS.each do |name, spec|
          verify_generator(result, format, domain, name, spec)
        end

        puts "" if format == :documentation
        result
      end

      def self.load_generators
        base = File.expand_path("../../generators/infrastructure/runtime_generator", __FILE__)
        Dir["#{base}/*.rb"].sort.each { |f| require f }
        require File.expand_path("../../generators/infrastructure/runtime_generator", __FILE__)
      end

      def self.verify_orchestrator(result, format, domain)
        check(result, format, "RuntimeGenerator", "produces 7 files") do
          gen = Generators::Infrastructure::RuntimeGenerator.new(domain, domain_module: "PizzasDomain")
          files = gen.generate
          raise "expected 7 files, got #{files.size}" unless files.size == 7
        end

        check(result, format, "RuntimeGenerator", "all valid Ruby") do
          gen = Generators::Infrastructure::RuntimeGenerator.new(domain, domain_module: "PizzasDomain")
          gen.generate.each do |file, source|
            RubyVM::InstructionSequence.compile(source)
          rescue SyntaxError => e
            raise "#{file}: #{e.message}"
          end
        end
      end

      def self.verify_generator(result, format, domain, name, spec)
        klass = Generators::Infrastructure.const_get(spec[:class_name])

        check(result, format, name, "generates #{spec[:method]}") do
          source = klass.new(domain, domain_module: "PizzasDomain").generate
          raise "missing method" unless source.include?("def #{spec[:method]}")
        end

        check(result, format, name, "module #{spec[:module_name]}") do
          source = klass.new(domain, domain_module: "PizzasDomain").generate
          raise "missing module" unless source.include?("module #{spec[:module_name]}")
        end

        check(result, format, name, "valid Ruby syntax") do
          source = klass.new(domain, domain_module: "PizzasDomain").generate
          RubyVM::InstructionSequence.compile(source)
        rescue SyntaxError => e
          raise e.message
        end

        check(result, format, name, "references aggregates") do
          source = klass.new(domain, domain_module: "PizzasDomain").generate
          has_feature = case name
          when "SubscriberWiring" then domain.event_subscribers.any?
          when "PolicyWiring"     then domain.policies.any?
          when "ServiceWiring"    then domain.services.any?
          when "WorkflowWiring"   then domain.workflows.any?
          when "SagaWiring"       then domain.sagas.any?
          else true
          end
          raise "missing Pizza" if has_feature && !source.include?("Pizza")
        end
      end

      def self.check(result, format, group, label)
        yield
        result.pass_count += 1
        if format == :documentation
          puts "  \e[32m✓\e[0m #{group}: #{label}"
        else
          print "."
        end
      rescue => e
        result.errors << { context: "Generators/#{group}", message: "#{label}: #{e.message}" }
        if format == :documentation
          puts "  \e[31m✗\e[0m #{group}: #{label} — #{e.message}"
        else
          print "\e[31mF\e[0m"
        end
      end
    end
  end
end

require "fileutils"
Hecks::Chapters.load_aggregates(
  Hecks::Bluebook::GeneratorInternalsParagraph,
  base_dir: File.expand_path("domain_gem_generator", __dir__)
)

module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::DomainGemGenerator
    #
    # Generates a complete domain gem on disk — aggregates, value objects, commands,
    # events, policies, queries, ports, adapters, specs, and a gemspec. Delegates
    # to FileWriter (disk I/O) and SpecWriter
    # (RSpec scaffolds). Part of the Generators::Infrastructure layer, invoked by
    # the CLI `hecks build` command and `Hecks.build`.
    #
    #   gen = DomainGemGenerator.new(domain, output_dir: "./generated")
    #   gen.generate  # => path to generated gem root
    #
    class DomainGemGenerator < Hecks::Generator
      include FileWriter
      include LlmsTxtWriter
      include SpecWriter

      # Creates a new DomainGemGenerator.
      #
      # @param domain [Hecks::BluebookModel::Structure::Domain] the parsed domain IR
      # @param version [String] SemVer string written into the generated gemspec
      #   (default: +"0.1.0"+)
      # @param output_dir [String] filesystem path where the gem directory will be
      #   created (default: +"."+, current working directory)
      def initialize(domain, version: "0.1.0", output_dir: ".")
        @domain = domain
        @version = version
        @output_dir = output_dir
      end

      # Generates the complete domain gem on disk.
      #
      # Creates the gem root directory under +output_dir+ and writes:
      # - A +.gemspec+ file
      # - An autoload entry point (+lib/<gem_name>.rb+)
      # - Aggregate classes with injected autoloads for value objects/entities
      # - Value object, entity, command, event, policy, subscriber, and
      #   specification files for every aggregate
      # - Query files under each aggregate's +queries/+ subdirectory
      # - Repository port modules under +ports/+
      # - In-memory adapter classes under +adapters/+
      # - Workflow, view, and service files
      # - RSpec specs for all aggregates, value objects, entities, commands, events
      # - A +Bluebook+ file containing the serialized DSL
      #
      # @return [String] the absolute path to the generated gem root directory
      def generate
        gem_name = @domain.gem_name
        mod = bluebook_module_name(@domain.name)
        root = File.join(@output_dir, gem_name)

        FileUtils.mkdir_p(root)

        generate_gemspec(root, gem_name, mod)
        generate_entry_point(root, gem_name, mod)
        generate_aggregates(root, gem_name, mod)
        generate_queries(root, gem_name, mod)
        generate_ports(root, gem_name, mod)
        generate_adapters(root, gem_name, mod)
        generate_workflows(root, gem_name, mod)
        generate_views(root, gem_name, mod)
        generate_services(root, gem_name, mod)
        generate_specs(root, gem_name, mod)
        generate_domain_rb(root)
        generate_llms_txt(root, gem_name, mod)

        root
      end
    end
    end
  end
end

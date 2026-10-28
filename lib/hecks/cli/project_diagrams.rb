require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `hecks project_diagrams`: boots a
    # domain, finds the bluebook it names, and writes its Mermaid diagrams
    # (`Projections::Diagrams`) under `docs/generated/diagrams/<bluebook>/` below the
    # root. Only this positional form writes; the launcher's `domain=… bluebook=…` question
    # prints the same files' text and writes nothing.
    module ProjectDiagrams
      module_function

      # Writes the bluebook's diagrams and prints each file written.
      #
      # @param argv [Array<String>] the domain path, then the bluebook's name
      # @param program [String] the name the usage line shows
      # @param root [String] the directory `docs/generated/diagrams/` lives under
      # @return [void]
      # @raise [SystemExit] with the usage line when an argument is missing, or when the
      #   domain has no bluebook of that name
      def call(argv, program:, root:)
        usage = "usage: #{program} <domain-path> <BluebookName>"
        domain_path = argv[0] or abort usage
        declaration_name = argv[1] or abort usage

        declaration, hecksagon = boot_bluebook(domain_path, declaration_name)
        directory = File.expand_path("docs/generated/diagrams/#{Naming.snake(declaration_name)}", root)

        report(declaration_name, directory, write_diagrams(declaration, hecksagon, directory))
      end

      # @api private
      # @return [Array(Object, Object)] the named bluebook and its hecksagon
      def boot_bluebook(domain_path, declaration_name)
        registry = Hecks.boot(File.expand_path(domain_path, Dir.pwd)).registry
        declaration = registry.bluebook(declaration_name) or abort "no bluebook named #{declaration_name}"
        [declaration, registry.hecksagon(declaration_name)]
      end

      # @api private
      def write_diagrams(declaration, hecksagon, directory)
        Projector.write(
          Projector.call(:diagrams, bluebook: declaration, options: { hecksagon: hecksagon }),
          directory, as: :files
        )
      end

      # @api private
      def report(declaration_name, directory, written)
        if written.empty?
          puts "#{declaration_name} declares no lifecycle, relationship, or dispatch to project yet"
        else
          puts "wrote #{written.size} diagram(s) to #{directory}:"
          written.each { |path| puts "  #{path}" }
        end
      end
    end
  end
end

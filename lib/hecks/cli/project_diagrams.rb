require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `hecks project_diagrams`: boots a
    # domain, finds the chapter it names, and writes its Mermaid diagrams
    # (`Projections::Diagrams`) under `docs/generated/diagrams/<chapter>/` below the
    # root. Only this positional form writes; the launcher's `domain=… chapter=…` question
    # prints the same files' text and writes nothing.
    module ProjectDiagrams
      module_function

      # Writes the chapter's diagrams and prints each file written.
      #
      # @param argv [Array<String>] the domain path, then the chapter's name
      # @param program [String] the name the usage line shows
      # @param root [String] the directory `docs/generated/diagrams/` lives under
      # @return [void]
      # @raise [SystemExit] with the usage line when an argument is missing, or when the
      #   domain has no chapter of that name
      def call(argv, program:, root:)
        usage = "usage: #{program} <domain-path> <ChapterName>"
        domain_path  = argv[0] or abort usage
        chapter_name = argv[1] or abort usage

        chapter, hecksagon = boot_chapter(domain_path, chapter_name)
        directory = File.expand_path("docs/generated/diagrams/#{Naming.snake(chapter_name)}", root)

        report(chapter_name, directory, write_diagrams(chapter, hecksagon, directory))
      end

      # @api private
      # @return [Array(Object, Object)] the named chapter and its hecksagon
      def boot_chapter(domain_path, chapter_name)
        registry = Hecks.boot(File.expand_path(domain_path, Dir.pwd)).registry
        chapter = registry.bluebook(chapter_name) or abort "no chapter named #{chapter_name}"
        [chapter, registry.hecksagon(chapter_name)]
      end

      # @api private
      def write_diagrams(chapter, hecksagon, directory)
        Projector.write(
          Projector.call(:diagrams, bluebook: chapter, options: { hecksagon: hecksagon }),
          directory, as: :files
        )
      end

      # @api private
      def report(chapter_name, directory, written)
        if written.empty?
          puts "#{chapter_name} declares no lifecycle, relationship, or dispatch to project yet"
        else
          puts "wrote #{written.size} diagram(s) to #{directory}:"
          written.each { |path| puts "  #{path}" }
        end
      end
    end
  end
end

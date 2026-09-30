require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `hecks project_diagrams` and `bin/project_diagrams`: boots a
    # domain, finds the chapter it names, and writes its Mermaid diagrams
    # (`Projections::Diagrams`) under `docs/generated/diagrams/<chapter>/` below the
    # root. Only this positional form writes; the launcher's `domain=… chapter=…` question
    # prints the same files' text and writes nothing.
    module ProjectDiagrams
      module_function

      def call(argv, program:, root:)
        usage = "usage: #{program} <domain-path> <ChapterName>"
        domain_path  = argv[0] or abort usage
        chapter_name = argv[1] or abort usage

        runtime   = Hecks.boot(File.expand_path(domain_path, Dir.pwd))
        chapter   = runtime.registry.bluebook(chapter_name) or abort "no chapter named #{chapter_name}"
        hecksagon = runtime.registry.hecksagon(chapter_name)
        directory = File.expand_path("docs/generated/diagrams/#{Naming.snake(chapter_name)}", root)

        written = Projector.write(
          Projector.call(:diagrams, bluebook: chapter, options: { hecksagon: hecksagon }),
          directory, as: :files
        )

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

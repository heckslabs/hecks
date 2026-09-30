require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `bin/project_glossary`: boots a domain and projects one chapter into its
    # Ubiquitous Language glossary, `glossary.md` plus `html/index.html` rendered from it, in the
    # domain's own `glossary/` folder.
    #
    # A field the deployment marks sensitive (`has_phi(readable_by:)` in the domain's `.hecksagon`)
    # is tagged in the glossary with its category. spec/glossary_spec.rb re-projects every one and
    # refuses a diff, so a committed glossary never lags the bluebook it describes.
    module ProjectGlossary
      module_function

      # Writes the chapter's glossary and prints each file written.
      #
      # @param argv [Array<String>] the domain path, then the chapter's name
      # @param program [String] the name the usage line shows
      # @return [void]
      # @raise [SystemExit] with the usage line when an argument is missing
      def call(argv, program: "bin/project_glossary")
        usage = "usage: #{program} <domain-path> <ChapterName>"
        domain_path  = argv[0] or abort usage
        chapter_name = argv[1] or abort usage

        domain  = File.expand_path(domain_path, Dir.pwd)
        runtime = Hecks.boot(domain)
        chapter = runtime.registry.bluebook(chapter_name)

        markings = runtime.registry.pending_privacy_markings.select do |marking|
          marking[:domain].to_s.start_with?("#{chapter_name}::")
        end

        written = Projector.write(
          Projector.call(:glossary, bluebook: chapter, options: { markings: markings }),
          File.join(domain, "glossary"), as: :files
        )

        puts "wrote #{written.size} file(s):"
        written.each { |path| puts "  #{path}" }
      end
    end
  end
end

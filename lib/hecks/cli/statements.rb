# frozen_string_literal: true

require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `hecks statements`: prints a booted domain's declared facts as plain
    # English sentences, through `Projections::Statements`.
    module Statements
      USAGE = "usage: hecks statements <domain-path> <ChapterName>"

      module_function

      # Boots the domain and prints one sentence per declared fact of the named chapter.
      #
      # @param argv [Array<String>] the domain path, then the chapter's name
      # @param cwd [String] what a relative domain path resolves against
      # @param out [IO] where the sentences go
      # @return [Integer] the exit status, 0 once printed
      # @raise [SystemExit] with the usage line when an argument is missing
      def call(argv, cwd: Dir.pwd, out: $stdout)
        domain_path, chapter_name = argv
        abort USAGE unless domain_path && chapter_name

        runtime = Hecks.boot(File.expand_path(domain_path, cwd))
        chapter = runtime.registry.bluebook(chapter_name)
        Hecks::Projector.call(:statements, bluebook: chapter).each { |statement| out.puts statement }
        0
      end
    end
  end
end

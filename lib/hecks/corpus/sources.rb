module Hecks
  module Corpus
    # How a domain's hecksagon names a chapter the gem carries and loads by name, as the QA
    # ledger's does (`Hecks::Chapters.load!("QualityControl")`).
    ATTACHED_CHAPTER = /Chapters\.load!\(\s*"([^"]+)"\s*\)/

    # Where a domain path keeps its bluebooks, and what a member boots. Extended onto `Corpus`.
    module Sources
      # Where a domain path keeps its bluebooks — `<domain>/bluebook/*.bluebook`, or the directory
      # itself when that holds none, or the chapter files its hecksagons load by name (the QA
      # ledger, `qa/bluebook`, holds only wiring: its chapter ships in
      # `lib/hecks/quality_control/`).
      #
      # @param domain_path [String] path to a domain directory
      # @return [Array<String>, nil] `.bluebook` file paths found, or nil when none
      def bluebook_files(domain_path)
        [File.join(domain_path, "bluebook"), domain_path].each do |dir|
          files = Dir[File.join(dir, "*.bluebook")]
          return files unless files.empty?
        end
        attached_chapter_files(domain_path)
      end

      # The bluebook files of every chapter a domain's own hecksagons load by name.
      #
      # @param domain_path [String] path to a domain directory
      # @return [Array<String>, nil] the chapters' `.bluebook` file paths, or nil when none is named
      def attached_chapter_files(domain_path)
        names = Dir[File.join(domain_path, "{bluebook/,}*.hecksagon")]
                .flat_map { |path| File.read(path).scan(ATTACHED_CHAPTER).flatten }.uniq
        files = names.flat_map { |name| Chapters.index.fetch(name, []) }
        files.empty? ? nil : files
      end

      # The directory holding `domain_path`'s bluebooks.
      #
      # @param domain_path [String] path to a domain directory
      # @return [String, nil] directory of the first `.bluebook` file found, or nil
      #   when `domain_path` holds none
      def bluebook_dir(domain_path)
        files = bluebook_files(domain_path)
        files && File.dirname(files.first)
      end
    end
  end
end

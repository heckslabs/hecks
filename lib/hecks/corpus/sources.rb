require_relative "../module_folders"
module Hecks
  module Corpus
    # How a domain's hecksagon names a bluebook the gem carries and loads by name: a
    # `Hecks.hecksagon "<Name>"` block whose first line is `bluebook_from :gem`. Captures the
    # bluebook's name.
    ATTACHED_BLUEBOOK = /Hecks\.hecksagon\s*\(?\s*"([^"]+)"\s*\)?\s*(?:do|\{)\s*\n\s*bluebook_from\s*:gem\b/

    # Where a domain path keeps its bluebooks, and what a member boots. Extended onto `Corpus`.
    module Sources
      # Where a domain path keeps its bluebooks — `<domain>/bluebook/*.bluebook`, or the directory
      # itself when that holds none, or the bluebook files its hecksagons load by name (a domain
      # that holds only wiring, whose bluebook ships in the gem).
      #
      # @param domain_path [String] path to a domain directory
      # @return [Array<String>, nil] `.bluebook` file paths found, or nil when none
      def bluebook_files(domain_path)
        [File.join(domain_path, "bluebook"), domain_path].each do |dir|
          files = ModuleFolders.all(dir)
          return files unless files.empty?
        end
        attached_bluebook_files(domain_path)
      end

      # The bluebook files of every bluebook a domain's own hecksagons load by name.
      #
      # @param domain_path [String] path to a domain directory
      # @return [Array<String>, nil] the bluebooks' `.bluebook` file paths, or nil when none is
      #   named
      def attached_bluebook_files(domain_path)
        names = Dir[File.join(domain_path, "{bluebook/,}*.hecksagon")]
                .flat_map { |path| File.read(path).scan(ATTACHED_BLUEBOOK).flatten }.uniq
        files = names.flat_map { |name| FrameworkBluebooks.index.fetch(name, []) }
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

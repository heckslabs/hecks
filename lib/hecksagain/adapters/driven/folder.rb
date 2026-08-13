require_relative "../../vocabulary"

module Hecksagain
  module Adapters
    class Folder
      DOMAIN_ORDER = Hecksagain::Vocabulary.fetch("LoadOrder")
      PORTS        = "ports"
      ADAPTERS     = "adapters"

      def initialize(settings: {}, root: nil)
        @settings = settings
        @root     = root
      end

      def load_library
        load_each(library(PORTS),    %w[*.port])
        load_each(library(ADAPTERS), %w[*/*.adapter */*/*.adapter])
      end

      def load_project(root)
        return unless root

        load_each(File.join(root, PORTS),    %w[*.port */*.port])
        load_each(File.join(root, ADAPTERS), %w[*.adapter */*.adapter */*/*.adapter])
      end

      def load_domain(directory) = load_each(directory, DOMAIN_ORDER)

      def load_each(directory, patterns)
        return unless File.directory?(directory)

        patterns.each do |pattern|
          Dir[File.join(directory, pattern)].sort.each { |file| Kernel.load(file) }
        end
      end

      def bluebook_directory(path)
        expanded = File.expand_path(path)
        nested   = File.join(expanded, "bluebook")

        return nested   if File.directory?(nested)
        return expanded if File.directory?(expanded)

        raise Errno::ENOENT, "no such domain directory: #{path}"
      end

      # THE DOMAIN YOU ARE STANDING IN. Walks up from `from` — the way git
      # finds `.git` — and answers the nearest directory a boot would accept,
      # or nil if there is not one above you.
      #
      # MARKED BY A `.hecksagon`, NOT BY A `.bluebook`. Chapters are
      # everywhere: era translations, the language's own self-hosted grammar,
      # and `spec/fixtures`, which holds a dozen unrelated ones in a single
      # directory. A `.hecksagon` is the file that says "this is a domain, and
      # here is how its aggregates are stored", which is exactly the claim a
      # caller is relying on when they omit the path.
      #
      # Both layouts, because `bluebook_directory` above accepts both: a
      # domain directory holding a `bluebook/` subdirectory (every example in
      # this corpus), or one holding the files directly.
      # NORMALISED TO THE OUTER DIRECTORY. Standing in `examples/banking/bluebook`,
      # the `.hecksagon` is right there, so a plain walk stops on the
      # `bluebook/` directory itself. Both boot identically — `bluebook_directory`
      # accepts either and `Loader.boot` takes `File.dirname` of what it gets,
      # so the registry root comes out the same — but `examples/banking` is the
      # directory a person names, and the one a `.world`'s `dir "data"` reads
      # as relative to.
      def domain_root(from = Dir.pwd)
        found = nearest_domain(File.expand_path(from))
        return nil unless found

        parent = File.dirname(found)
        File.basename(found) == "bluebook" && domain?(parent) ? parent : found
      end

      def nearest_domain(current)
        loop do
          return current if domain?(current)

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      def domain?(directory)
        !Dir[File.join(directory, "*.hecksagon")].empty? ||
          !Dir[File.join(directory, "bluebook", "*.hecksagon")].empty?
      end

      def shared_root(given, directory)
        return File.expand_path(given) if given

        current = directory
        loop do
          return current if File.directory?(File.join(current, PORTS)) ||
                            File.directory?(File.join(current, ADAPTERS))

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      def library(folder)
        File.expand_path("../../#{folder}", __dir__)
      end
    end
  end
end

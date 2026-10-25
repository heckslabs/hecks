require_relative "../../vocabulary"
require_relative "../../ports/loading"
require_relative "../../sentence_form"

module Hecks
  module Adapters
    # Loads a domain's files off disk in `Vocabulary.fetch("LoadOrder")` order and finds
    # a domain's root directory. Used by `Hecks.boot(path)` when given a directory.
    class Folder
      DOMAIN_ORDER = Hecks::Vocabulary.fetch("LoadOrder")
      PORTS        = "ports".freeze
      ADAPTERS     = "adapters".freeze

      # @param settings [Hash] accepted but not read by this class
      # @param root [String, nil] accepted but not read by this class
      def initialize(settings: {}, root: nil)
        @settings = settings
        @root     = root
      end

      # Loads the framework's own bundled ports and adapters from `lib/hecks/{ports,adapters}`.
      #
      # @return [void]
      def load_library
        load_each(library(PORTS),    %w[*.port])
        load_each(library(ADAPTERS), %w[*/*.adapter */*/*.adapter])
      end

      # Loads a shared root's own ports and adapters, if one was found.
      #
      # @param root [String, nil] the shared root directory, as `shared_root` resolves it;
      #   nil is a no-op
      # @return [void]
      def load_project(root)
        return unless root

        load_each(File.join(root, PORTS),    %w[*.port */*.port])
        load_each(File.join(root, ADAPTERS), %w[*.adapter */*.adapter */*/*.adapter])
      end

      # Loads bluebook chapters first, judged once as a deferred group, then everything
      # else in `DOMAIN_ORDER`. Deferring keeps a chapter split across files from being
      # judged before its later files exist (see MetaValidator.defer).
      #
      # Then the overlays merge into the base hecksagon/world: the copy's own, then the named
      # `environment:` one (see `load_overlay`); a missing overlay file is skipped.
      #
      # @param directory [String] the domain's bluebook directory to load, as
      #   `bluebook_directory` resolves it
      # @param environment [String, nil] the environment overlay to load after the domain's
      #   own files (e.g. `"production"`); nil loads no overlay
      # @return [void]
      def load_domain(directory, environment: nil)
        boundary = DOMAIN_ORDER.rindex { |pattern| pattern.end_with?(".bluebook") }
        if boundary
          load_bluebooks(directory, DOMAIN_ORDER[0..boundary])
          load_each(directory, DOMAIN_ORDER[(boundary + 1)..])
        else
          load_each(directory, DOMAIN_ORDER)
        end

        load_overlay(directory, environment)
      end

      # The overlay one copy of a domain keeps for itself, such as the database its own runs
      # record to. `.gitignore` keeps it out of the repository, so no other copy ever reads it.
      LOCAL_OVERLAY = "local".freeze

      # Loads the copy's own overlay, then an environment's, each `.hecksagon` then `.world`,
      # when present. The environment loads last, so `memory` still wins over a local database.
      #
      # @param directory [String] the directory holding the `environments/` folder
      # @param environment [String, nil] the environment name; nil loads only the local overlay
      # @return [void]
      def load_overlay(directory, environment)
        [LOCAL_OVERLAY, environment].compact.uniq.each do |name|
          load_each(directory, [File.join("environments", "#{name}.hecksagon")])
          load_each(directory, [File.join("environments", "#{name}.world")])
        end
      end

      # Loads every bluebook in a folder as one declaration set, judged after all are loaded
      # so cross-file references never meet a partial chapter.
      #
      # @param directory [String] the directory to glob for bluebook chapter files
      # @param patterns [Array<String>] glob patterns, relative to `directory`, selecting the
      #   chapter files to load
      # @return [void]
      def load_bluebooks(directory, patterns = ["*.bluebook"])
        Bluebook::MetaValidator.defer { load_each(directory, patterns) }
        Bluebook::MetaValidator.judge_deferred!(Hecks.current_registry)
      end

      # Loads exactly the named files in place, without globbing (see `Loader.boot_files`).
      #
      # Files load by category, not in the caller's order: bluebooks (judged as one deferred
      # group), then hecksagons, then worlds, since a hecksagon may reference bluebook constants.
      #
      # @param files [Array<String>] file paths to load, relative to `bluebook_directory`
      # @param environment [String, nil] the environment name whose overlay, if present,
      #   loads after the selected files
      # @return [void]
      def load_selected(files, environment: nil)
        bluebooks, rest = files.partition { |f| f.end_with?(".bluebook") }
        load_selected_bluebooks(bluebooks)
        %w[.hecksagon .world].each do |ext|
          rest.select { |f| f.end_with?(ext) }.sort.each { |f| Kernel.load(f) }
        end
        load_overlay(File.dirname(files.first), environment) if environment
      end

      # Loads the given bluebook files as one deferred group, judged once after all are loaded.
      #
      # @param bluebooks [Array<String>] bluebook file paths; none means nothing loads
      # @return [void]
      def load_selected_bluebooks(bluebooks)
        return if bluebooks.empty?

        Bluebook::MetaValidator.defer { bluebooks.sort.each { |f| load_file(f) } }
        Bluebook::MetaValidator.judge_deferred!(Hecks.current_registry)
      end

      # Loads one file. A `.bluebook` written as sentences is declared through the Ruby text the
      # Rust parser renders from it; every other file is loaded as Ruby.
      #
      # @param file [String] the file to load
      # @return [void]
      def load_file(file)
        if file.end_with?(".bluebook") && File.file?(file) && SentenceForm.sentences?(file)
          SentenceForm.load(file)
        else
          Kernel.load(file)
        end
      end

      # Loads every file under `directory` matching any of `patterns`, in pattern order.
      #
      # A no-op if `directory` does not exist.
      #
      # @param directory [String] the directory to search
      # @param patterns [Array<String>] glob patterns, relative to `directory`, of files to
      #   load with `Kernel.load`
      # @return [void]
      def load_each(directory, patterns)
        return unless File.directory?(directory)

        patterns.each do |pattern|
          Dir[File.join(directory, pattern)].each { |file| load_file(file) }
        end
      end

      # Resolves a domain path to the directory that actually holds its bluebook files.
      #
      # @param path [String] a domain directory, holding either a `bluebook/` subdirectory or
      #   its chapter files directly
      # @return [String] the `bluebook/` subdirectory's absolute path, if one exists; `path`'s
      #   own absolute path otherwise
      # @raise [Errno::ENOENT] if neither directory exists
      def bluebook_directory(path)
        expanded = File.expand_path(path)
        nested   = File.join(expanded, "bluebook")

        return nested   if File.directory?(nested)
        return expanded if File.directory?(expanded)

        raise Errno::ENOENT, "no such domain directory: #{path}"
      end

      # Finds the nearest domain directory at or above `from`, or nil if there is not one.
      #
      # Walks up from `from`, like git finding `.git`. A domain is marked by a `.hecksagon`,
      # not a `.bluebook`, since chapters also appear in translations and fixtures.
      #
      # A `bluebook/` subdirectory result is normalised to its parent, the directory
      # a `.world`'s `dir "data"` is relative to.
      #
      # @param from [String] the directory to walk up from; defaults to the process's current
      #   working directory
      # @return [String, nil] the resolved domain directory's absolute path, or nil if none is
      #   found above `from`
      def domain_root(from = Dir.pwd)
        found = nearest_domain(File.expand_path(from))
        return nil unless found

        parent = File.dirname(found)
        File.basename(found) == "bluebook" && domain?(parent) ? parent : found
      end

      # Walks up from `current` until it finds a domain directory, or reaches the filesystem
      # root.
      #
      # @param current [String] the absolute directory path to start searching from
      # @return [String, nil] the nearest directory (`current` or an ancestor) that `domain?`
      #   accepts, or nil if none is found before the filesystem root
      def nearest_domain(current)
        loop do
          return current if domain?(current)

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      # Reports whether `directory` is a domain root.
      #
      # @param directory [String] the directory to check
      # @return [Boolean] true if `directory`, or its `bluebook/` subdirectory, holds a
      #   `.hecksagon` file
      def domain?(directory)
        !Dir[File.join(directory, "*.hecksagon")].empty? ||
          !Dir[File.join(directory, "bluebook", "*.hecksagon")].empty?
      end

      # Resolves the shared root a domain's own ports/adapters overlay from.
      #
      # @param given [String, nil] an explicit shared-root override; returned expanded as-is
      #   when present
      # @param directory [String] the domain directory to search upward from when `given` is
      #   nil
      # @return [String, nil] `given`'s expanded path, or the nearest ancestor of `directory`
      #   holding a `ports` or `adapters` folder; nil if none is found before the filesystem
      #   root
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

      # Resolves the framework's own bundled `folder` directory under `lib/hecks`.
      #
      # @param folder [String] `"ports"` or `"adapters"`, the framework's own bundled
      #   directory name
      # @return [String] the absolute path to `lib/hecks/<folder>`
      def library(folder)
        File.expand_path("../../#{folder}", __dir__)
      end
    end
  end
end

Hecks::Ports::Loading.bootstrap_with(Hecks::Adapters::Folder)

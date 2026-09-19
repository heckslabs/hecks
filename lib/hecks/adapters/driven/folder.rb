require_relative "../../vocabulary"

module Hecks
  module Adapters
    # The filesystem-backed loader — glob-and-`Kernel.load` a domain's own
    # `.port`/`.adapter`/`.bluebook`/`.hecksagon`/`.world`/environment-overlay
    # files off disk, in the order `Vocabulary.fetch("LoadOrder")` requires,
    # and locate a domain's own root directory by walking up from any file
    # inside it looking for a `.hecksagon`. What `Hecks.boot(path)` uses when
    # a caller names a directory rather than an explicit file list (see
    # `Loader.boot_files` for that other path).
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

      # Chapters first, judged once, then everything that reads them.
      # A chapter may be split across files (the language's own grammar is
      # nine), and judging file one before files two-through-nine exist
      # refuses references that are perfectly well declared a file later —
      # see MetaValidator.defer for the whole reasoning. DOMAIN_ORDER
      # already places every `*.bluebook` ahead of hecksagons and worlds,
      # so the window ends at the last chapter pattern rather than at a
      # hand-written list this would otherwise have to keep in step.
      #
      # `environment:` — one more pair of files, loaded last, not a glob.
      # Recovered, not new — see Runtime::Loader.boot's own comment for
      # the provenance. A caller passing `Hecks.boot(path, environment:
      # "production")` gets exactly `environments/production.hecksagon`
      # and `environments/production.world` loaded, whichever exist (a
      # missing one is a silent no-op — not every environment overrides
      # both; see docs/implemented/guides/wiring.md's "Swapping wiring per
      # environment" for the motivating case: swapping a driven adapter
      # — e.g. a real payment gateway for a mock one, or a hosting
      # layer's tenancy settings — without an `if`/`else` anywhere in
      # the domain's own wiring). Never matched by `DOMAIN_ORDER`'s own
      # globs (all non-recursive, none named `environments/*`), so this
      # is the only thing that ever reaches them. Loaded as genuine
      # `Hecks.hecksagon "SameDomain" do ... end` / `Hecks.world
      # "SameDomain" do ... end` blocks — merged into the base file's
      # own hecksagon/world (Registry#add_hecksagon / #add_world,
      # concatenate/override rather than replace), so an overlay can
      # rebind or add settings for anything the base file declared
      # without needing to know what else the base file said.
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

        return unless environment

        load_each(directory, [File.join("environments", "#{environment}.hecksagon")])
        load_each(directory, [File.join("environments", "#{environment}.world")])
      end

      # Every bluebook in a folder is one declaration set. Individual files
      # remain organized in the domain expert's language; the folder is the
      # unit callers load. Builders group declarations by the chapter name in
      # each file, so a folder may hold more than one chapter without a catalog.
      # Sorting makes source order deterministic while the deferred window keeps
      # cross-file references from being judged against a partial chapter.
      #
      # @param directory [String] the directory to glob for bluebook chapter files
      # @param patterns [Array<String>] glob patterns, relative to `directory`, selecting the
      #   chapter files to load
      # @return [void]
      def load_bluebooks(directory, patterns = ["*.bluebook"])
        Bluebook::MetaValidator.defer { load_each(directory, patterns) }
        Bluebook::MetaValidator.judge_deferred!(Hecks.current_registry)
      end

      # The explicit-file sibling of `load_domain` — for a caller that names
      # its own exact files rather than a directory to glob (`Loader.boot_files`,
      # behind `Hecks.boot_files`). No `Dir.glob`, no copying: every path here
      # is a real file on disk, wherever it actually lives, loaded in place —
      # a `.behaviors` file's `loads` scopes a boot this way specifically so a
      # per-test boot never has to fake isolation by staging bluebooks into a
      # tmpdir (see Loader.boot_files's own header for why that pattern is a
      # hazard, not a convenience).
      #
      # Ordered by category, not by the caller's own list order — same four
      # groups `Vocabulary.fetch("LoadOrder")` walks a directory in
      # (bluebook chapters, translations, hecksagons, worlds), because a
      # hecksagon can reference a bluebook's own constants and must not load
      # first regardless of which order a caller happened to write `loads
      # "x.hecksagon", "x.bluebook"` in. Bluebook chapters are judged as one
      # deferred group exactly like `load_domain` does, for the identical
      # forward-reference reason (MetaValidator.defer's own header).
      # @param files [Array<String>] file paths to load, relative to `bluebook_directory`
      # @param environment [String, nil] the environment name whose overlay, if present,
      #   loads after the selected files
      # @return [void]
      def load_selected(files, environment: nil)
        bluebooks, rest = files.partition { |f| f.end_with?(".bluebook") }

        if bluebooks.any?
          Bluebook::MetaValidator.defer { bluebooks.sort.each { |f| Kernel.load(f) } }
          Bluebook::MetaValidator.judge_deferred!(Hecks.current_registry)
        end

        %w[.hecksagon .world].each do |ext|
          rest.select { |f| f.end_with?(ext) }.sort.each { |f| Kernel.load(f) }
        end

        return unless environment

        directory = File.dirname(files.first)
        load_each(directory, [File.join("environments", "#{environment}.hecksagon")])
        load_each(directory, [File.join("environments", "#{environment}.world")])
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
          Dir[File.join(directory, pattern)].each { |file| Kernel.load(file) }
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
      # **The domain you are standing in**. Walks up from `from` — the way git
      # finds `.git` — and answers the nearest directory a boot would accept,
      # or nil if there is not one above you.
      #
      # Marked by a `.hecksagon`, not by a `.bluebook`. Chapters are
      # everywhere: era translations, the language's own self-hosted grammar,
      # and `spec/fixtures`, which holds a dozen unrelated ones in a single
      # directory. A `.hecksagon` is the file that says "this is a domain, and
      # here is how its aggregates are stored", which is exactly the claim a
      # caller is relying on when they omit the path.
      #
      # Both layouts, because `bluebook_directory` above accepts both: a
      # domain directory holding a `bluebook/` subdirectory (every example in
      # this corpus), or one holding the files directly.
      # Normalised to the outer directory. Standing in `examples/banking/bluebook`,
      # the `.hecksagon` is right there, so a plain walk stops on the
      # `bluebook/` directory itself. Both boot identically — `bluebook_directory`
      # accepts either and `Loader.boot` takes `File.dirname` of what it gets,
      # so the registry root comes out the same — but `examples/banking` is the
      # directory a person names, and the one a `.world`'s `dir "data"` reads
      # as relative to.
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

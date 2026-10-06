require_relative "fuzzing/target_capabilities"
require_relative "corpus/routes"
require_relative "corpus/rust"
require_relative "corpus/sources"

module Hecks
  # The corpus: every place in this repo that holds a real domain, named once.
  # Plain Dir/File only — the tools require this before booting anything.
  module Corpus
    ROOT = File.expand_path("../..", __dir__).freeze

    Member = Struct.new(:stem, :kind, :path)

    # **One domain per directory** — its bluebooks sit in `<dir>/bluebook/`
    # or directly in `<dir>` (see `bluebook_files`). Stemmed by directory.
    DIRECTORY_KINDS = {
      example:   "examples/*",
      stress:    "qa/stress_domains/*",
      semantics: "spec/corpus/semantics/domains/*",
      # The Hecks domain (ADR 0080): its chapters share one namespace and one hecksagon, so
      # they load together, as a directory, never file by file.
      hecks:     "lib/hecks/hecks",
      # A package vendored via `attaches ... from: :vendor` — nested inside the
      # consuming example's own checkout, not this gem's own framework/bluebook/.
      vendored:  "examples/*/vendor/embryonaut_bluebooks/*"
    }.freeze

    # **One chapter per file**. Stemmed by the path below the glob's fixed
    # prefix, so a nested fixture keeps its subdirectory (`eras/base`)
    # and never collides with a same-named file elsewhere in the kind.
    FILE_KINDS = {
      grammar:   "lib/hecks/grammar/*.bluebook",
      framework: "lib/hecks/framework/bluebook/*.bluebook",
      qa:        "lib/hecks/quality_control/*.bluebook",
      language:  "lib/hecks/language/**/*.bluebook",
      deploy:    "lib/hecks/deploy/bluebook/*.bluebook",
      site:      "lib/hecks/site/bluebook/*.bluebook",
      tickets:   "lib/hecks/tickets/bluebook/*.bluebook",
      tenancy:   "lib/hecks/tenancy/bluebook/*.bluebook",
      sme:       "lib/hecks/sme/bluebook/*.bluebook",
      fixture:   "spec/fixtures/**/*.bluebook"
    }.freeze

    KINDS = (DIRECTORY_KINDS.keys + FILE_KINDS.keys).freeze

    extend Rust
    extend Sources

    module_function

    # Lists corpus members of the given kinds (every kind, by default).
    #
    # @param kinds [Array<Symbol>] corpus kinds to include, from `KINDS`; every kind
    #   when empty
    # @param root [String] repository root to search under
    # @return [Array<Member>] matching members
    # @raise [ArgumentError] if `kinds` names a kind not in `KINDS`
    def members(*kinds, root: ROOT)
      kinds = KINDS if kinds.empty?
      kinds.flat_map { |kind| kind_members(kind, root) }
    end

    # @return [Array<Member>] the members of one kind: a directory each, or a file each
    # @raise [ArgumentError] if `kind` is not in `KINDS`
    def kind_members(kind, root)
      if (glob = DIRECTORY_KINDS[kind])
        directory_members(kind, root, glob)
      elsif (glob = FILE_KINDS[kind])
        file_members(kind, root, glob)
      else
        raise ArgumentError, "unknown corpus kind #{kind.inspect} — known: #{KINDS.join(", ")}"
      end
    end

    def directory_members(kind, root, glob)
      Dir.glob(File.join(root, glob)).select { |path| File.directory?(path) }.sort
         .map { |dir| Member.new(File.basename(dir), kind, dir) }
    end

    def file_members(kind, root, glob)
      prefix = File.join(root, glob[/\A[^*]*/].chomp("/"))
      Dir.glob(File.join(root, glob))
         .map { |file| Member.new(file.delete_prefix("#{prefix}/").delete_suffix(".bluebook"), kind, file) }
    end

    # What a boot loads for a member — a directory kind's bluebook
    # directory, or a file kind's own file.
    #
    # @param member [Member] the corpus member
    # @return [String, nil] the path to boot, or nil when a directory member holds
    #   no bluebook
    def source_of(member)
      DIRECTORY_KINDS.key?(member.kind) ? bluebook_dir(member.path) : member.path
    end

    # The route a repo-relative path takes instead of the sweep — the
    # first one it matches — or `nil` when the sweep boots it.
    #
    # @param relative_path [String] a corpus member's path, relative to the repo root
    # @return [Route, nil] the first matching route, or nil when the sweep boots it
    def route_for(relative_path)
      ROUTES.find { |route| route.pattern.match?(relative_path) }
    end

    # Every kind hecks model_check walks: excludes language/deploy (checked
    # elsewhere) and anything a route already sends to its own destination.
    MODEL_CHECK_KINDS = %i[example grammar framework vendored qa stress fixture hecks].freeze

    # Every corpus member `hecks model_check` and `spec/model_check_spec.rb` walk.
    #
    # @param root [String] repository root to search under
    # @return [Array<Member>] members of `MODEL_CHECK_KINDS`, less any routed elsewhere
    def model_check_members(root: ROOT)
      members(*MODEL_CHECK_KINDS, root: root).reject { |member| route_for(member.path.delete_prefix("#{root}/")) }
    end

    # **The ledger sweeps itself** — its own chapter is a domain like any
    # other, and the one rotation member that is neither an example nor a
    # stress domain.
    ROTATION_LEDGER = { "quality_control" => "qa/bluebook" }.freeze

    # What the QA rotation is made of — every example and stress domain,
    # plus the ledger, as `reference => repo-relative path` — derived, not hand-kept.
    #
    # @param root [String] repository root to search under
    # @return [Hash{String => String}] each rotation member's stem/reference mapped
    #   to its repo-relative path
    def rotation_targets(root: ROOT)
      members(:example, :stress, root: root)
        .to_h { |member| [member.stem, member.path.delete_prefix("#{root}/")] }
        .merge(ROTATION_LEDGER)
    end

    # Every bootable domain in the project — any directory holding a
    # `.bluebook` no route sends elsewhere (a `bluebook/` folder stands for its parent).
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] absolute paths of every sweepable domain directory
    def sweepable_domains(root = ROOT)
      Dir.chdir(root) do
        Dir.glob("**/*.bluebook")
           .reject { |path| route_for(path) }
           .map { |path| File.dirname(path) }
           .map { |dir| File.basename(dir) == "bluebook" ? File.dirname(dir) : dir }
           .uniq.sort
           .map { |dir| File.join(root, dir) }
      end
    end

    # Sweepable domains a fuzz cannot boot from its copy, by repo-relative directory, each with
    # the reason. A fuzz boots a tmpdir copy of a domain to isolate its state.
    FUZZ_UNBOOTABLE = {
      "lib/hecks/hecks"                                           => "the gem's own chapter; model_check covers it",
      "spec/fixtures/qa_discover_external_domains/projects/hecks" => "declares the reserved chapter name `Hecks`"
    }.freeze

    # Every sweepable domain a fuzz can boot: `sweepable_domains` less `FUZZ_UNBOOTABLE`.
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] absolute paths of the domain directories `hecks fuzz` sweeps
    def fuzzable_domains(root = ROOT)
      sweepable_domains(root) - FUZZ_UNBOOTABLE.keys.map { |dir| File.join(root, dir) }
    end

    # The domain directory a member stands for, spelled the way
    # `sweepable_domains` spells it: a `bluebook/` folder is its parent.
    #
    # @param member [Member] the corpus member
    # @return [String] the member's owning domain directory path
    def domain_dir_of(member)
      dir = File.directory?(member.path) ? member.path : File.dirname(member.path)
      File.basename(dir) == "bluebook" ? File.dirname(dir) : dir
    end

    # The chapter a bluebook declares — `Hecks.bluebook "<Name>"` — read off
    # the file rather than guessed from its name, since the two can differ.
    #
    # @param bluebook_path [String, Array<String>] a `.bluebook` file path, or an
    #   array whose first element is used
    # @return [String, nil] the declared chapter name, or nil when the file never
    #   declares one
    def chapter_name_of(bluebook_path)
      bluebook_path = Array(bluebook_path).first
      header = File.foreach(bluebook_path).find { |line| line =~ /\A\s*Hecks\.bluebook\s+"([^"]+)"/ }
      header && Regexp.last_match(1)
    end
  end
end

require_relative "fuzzing/target_capabilities"

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
      tenancy:   "lib/hecks/tenancy/bluebook/*.bluebook",
      sme:       "lib/hecks/sme/bluebook/*.bluebook",
      fixture:   "spec/fixtures/**/*.bluebook"
    }.freeze

    KINDS = (DIRECTORY_KINDS.keys + FILE_KINDS.keys).freeze

    # A route sends what the sweep does not boot elsewhere; each entry's
    # `check` (:named_in, :gitignored, :gap) is verified by
    # spec/corpus_accounting_spec.rb, matched in order.
    Route = Struct.new(:pattern, :check, :destination, :names, :why)

    ROUTES = [
      Route.new(%r{\Atmp/}, :gitignored, ".gitignore", "tmp/",
                "scratch output — generated and mined candidate domains, fuzz failures — never committed"),
      Route.new(%r{/\.aws-sam/}, :gitignored, ".gitignore", ".aws-sam/",
                "SAM build output — a vendored copy of real sources, never committed"),
      Route.new(%r{/data/eras/}, :gitignored, ".gitignore", "**/data/eras/",
                "era snapshots a file adapter writes at runtime, never committed"),
      Route.new(%r{\Arust/}, :named_in, "rust/parser/tests/gates.rs", :each_file,
                "the Rust parser's own fixtures, each loaded by its gate tests"),
      Route.new(%r{/translations/}, :named_in, "spec/translation/committed_edges_spec.rb", "bluebook/translations",
                "translation edges, not chapters; each must load, chain era to era, and end at the storage " \
                "shape its bluebook declares today"),
      Route.new(%r{\Alib/hecks/forms/examples/}, :named_in, "spec/forms/app_spec.rb", :each_file,
                "a Forms presentation config wearing the .bluebook extension"),
      Route.new(%r{\Aspec/fixtures/eras/}, :named_in, "spec/runtime/storage_shape_spec.rb", "fixtures/eras",
                "deliberately conflicting versions of one domain; each must classify as the verdict " \
                "its filename declares (bump_* / same_*)"),
      Route.new(%r{\Aspec/fixtures/model_check/}, :named_in, "spec/model_check_spec.rb", :each_file,
                "domains broken on purpose; each must produce exactly the finding kinds it is built to trigger"),
      # hecks fuzz sweeps it too, once Fuzzing::Replay coerces value-object args
      # before recomputing givens — today it doesn't, so this given reads as
      # wrongly admitted.
      Route.new(%r{\Aspec/fixtures/rust_host/}, :named_in, "rust/host/src/web.rs", "checkout_fixture",
                "the Rust host's checkout fixture, pinned by its web and /api tests")
    ].freeze

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
      kinds.flat_map do |kind|
        if (glob = DIRECTORY_KINDS[kind])
          Dir.glob(File.join(root, glob)).select { |path| File.directory?(path) }.sort
             .map { |dir| Member.new(File.basename(dir), kind, dir) }
        elsif (glob = FILE_KINDS[kind])
          prefix = File.join(root, glob[/\A[^*]*/].chomp("/"))
          Dir.glob(File.join(root, glob))
             .map { |file| Member.new(file.delete_prefix("#{prefix}/").delete_suffix(".bluebook"), kind, file) }
        else
          raise ArgumentError, "unknown corpus kind #{kind.inspect} — known: #{KINDS.join(', ')}"
        end
      end
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

    # How a domain's hecksagon names a chapter the gem carries and loads by name, as the QA
    # ledger's does (`Hecks::Chapters.load!("QualityControl")`).
    ATTACHED_CHAPTER = /Chapters\.load!\(\s*"([^"]+)"\s*\)/

    # Where a domain path keeps its bluebooks — `<domain>/bluebook/*.bluebook`, or the directory
    # itself when that holds none, or the chapter files its hecksagons load by name (the QA
    # ledger, `qa/bluebook`, holds only wiring: its chapter ships in `lib/hecks/quality_control/`).
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

    # Every Rust-facing list reads `rust/Cargo.toml`'s `[features]` as its
    # one source, rather than each consumer typing it out by hand.
    GENERATED_DIR = "rust/src/generated".freeze
    RUST_DOMAIN_KINDS = %i[example stress fixture].freeze

    RustDomain = Struct.new(:feature, :dir, :kind)

    # `check: :named_in` — `destination` must name `names`.
    Elsewhere = Struct.new(:check, :destination, :names, :why)

    RUST_ELSEWHERE = {
      "meta" => Elsewhere.new(:named_in, "lib/hecks/tools/regeneration_run.rb", "rust/src/generated",
                              "the self-hosted grammar (lib/hecks/language), not a domain directory — every " \
                              "hecks project_rust run rewrites it, so the drift check diffs it with the rest " \
                              "of rust/src/generated, and there is no directory to fuzz")
    }.freeze

    # Every place a Rust-facing domain's own `attaches` (or the deprecated `uses_framework` /
    # `uses_embryonaut_bluebook`) attachment could be declared.
    #
    # @param root [String] repository root to search under
    # @return [String] every reachable hecksagon file's own text, joined by newlines
    def rust_attachment_hecksagon_text(root: ROOT)
      rust_domains(root: root).flat_map { |domain| Dir.glob(File.join(domain.dir, "**", "*.hecksagon")) }
                              .map { |path| File.read(path) }.join("\n")
    end

    # **Shrink-only**: a generated module `hecks rust_coverage` still flags.
    # `hecks corpus_rust_coverage --rust-coverage` requires each entry to still fail, so a
    # newly-passing module breaks the build until removed here.
    RUST_COVERAGE_PENDING = {}.freeze

    # The Cargo `[features]` table's raw text.
    #
    # @param root [String] repository root to search under
    # @return [String] the table's text, or `""` when `rust/Cargo.toml` has none
    def cargo_features_table(root: ROOT)
      File.read(File.join(root, "rust/Cargo.toml"))[Fuzzing::TargetCapabilities::FEATURES_TABLE] || ""
    end

    # Every feature name Cargo declares with no dependency array of its own.
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] feature names, in file order
    def cargo_features(root: ROOT)
      cargo_features_table(root: root).scan(/^(\w+)\s*=\s*\[\]/).flatten
    end

    # The feature `hecks project_rust` last wrote as Cargo's `default`.
    #
    # @param root [String] repository root to search under
    # @return [String, nil] the default feature's name, or nil when Cargo.toml
    #   declares none
    def cargo_default(root: ROOT)
      cargo_features_table(root: root)[/^default\s*=\s*\["(\w+)"\]/, 1]
    end

    # Every in-repo domain directory whose name is a Cargo feature, sorted
    # by path — disambiguated by the generated module's metadata.rs stamp when one exists.
    #
    # @param root [String] repository root to search under
    # @return [Array<RustDomain>] each Rust-facing domain, sorted by directory path
    def rust_domains(root: ROOT)
      features = cargo_features(root: root)
      members(*RUST_DOMAIN_KINDS, root: root)
        .map { |member| [domain_dir_of(member), member.kind] }
        .uniq(&:first)
        .select { |dir, _| rust_domain_dir?(dir, features, root) }
        .sort_by(&:first)
        .map { |dir, kind| RustDomain.new(File.basename(dir).downcase, dir, kind) }
    end

    # Tells whether `dir` is the real source directory for its Cargo feature.
    #
    # @param dir [String] a candidate domain directory
    # @param features [Array<String>] known Cargo feature names
    # @param root [String] repository root `dir` is rooted under
    # @return [Boolean]
    def rust_domain_dir?(dir, features, root)
      feature = File.basename(dir).downcase
      source = generated_source(feature, root: root)
      features.include?(feature) && (source.nil? || source == dir.delete_prefix("#{root}/"))
    end

    # The stamp hecks project_rust writes into metadata.rs, e.g.
    # `examples/pizzas` or `the self-hosted language (...)`, with any
    # ` (attaches "X")`/` (attaches "x", from: :vendor)` suffix stripped (the deprecated
    # `uses_framework` / `uses_embryonaut_bluebook` spellings too).
    SOURCE_STAMP = /
      GENERATED\ by\ hecks\ project_rust\ —\ (.+?)
      (?:\ \((?:attaches|uses_framework|uses_embryonaut_bluebook)\ "\w+"(?:,\ from:\ :vendor)?\))?
      's\ own\ canonical\ IR,
    /x

    # Where a generated module came from, read off the stamp `hecks project_rust`
    # writes into its metadata.rs.
    #
    # @param module_name [String] a generated module's name
    # @param root [String] repository root to search under
    # @return [String, nil] the source path the stamp names, or nil when the module
    #   is not generated
    def generated_source(module_name, root: ROOT)
      metadata = File.join(root, GENERATED_DIR, module_name, "metadata.rs")
      File.file?(metadata) ? File.read(metadata)[SOURCE_STAMP, 1] : nil
    end

    # Every module directory under `rust/src/generated`.
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] generated module names, sorted
    def generated_modules(root: ROOT)
      Dir.children(File.join(root, GENERATED_DIR)).select { |name| File.directory?(File.join(root, GENERATED_DIR, name)) }.sort
    end

    # Tells whether `feature` has already been generated (has a merged.rs).
    #
    # @param feature [String] a Cargo feature / domain name
    # @param root [String] repository root to search under
    # @return [Boolean]
    def generated?(feature, root: ROOT)
      File.file?(File.join(root, GENERATED_DIR, feature, "merged.rs"))
    end

    # Chapters attached via `kind` that get a generated module as a side
    # effect of the attaching domain's regen, with no merged.rs of their own.
    #
    # @param kind [Symbol] :framework or :vendored
    # @param root [String] repository root to search under
    # @return [Array<String>] stems with a generated module but no merged.rs
    #   of their own
    def rust_side_chapters(kind, root: ROOT)
      modules = generated_modules(root: root)
      members(kind, root: root).map(&:stem)
                               .select do |stem|
                                 module_name = Naming.pascal(stem).downcase
                                 modules.include?(module_name) && !generated?(module_name, root: root)
                               end
    end

    # The generated module name a `:framework`/`:vendored` stem writes
    # under — strips underscores, so it can differ from the raw stem.
    #
    # @param stem [String] a `:framework`/`:vendored` corpus member's stem
    # @return [String] the generated module's own directory name
    def rust_side_module_name(stem)
      Naming.pascal(stem).downcase
    end

    # Names the framework chapters Rust carries as modules, beside its domains' own bluebooks.
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] generated module names for the `:framework` corpus members
    def rust_framework_chapters(root: ROOT)
      rust_side_chapters(:framework, root: root)
    end

    # Names the vendored chapters Rust carries as modules, beside its domains' own bluebooks.
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] generated module names for the `:vendored` corpus members
    def rust_vendored_chapters(root: ROOT)
      rust_side_chapters(:vendored, root: root)
    end

    # Chapters an in-repo Rust domain carries beside its own bluebook,
    # written as a module by `hecks project_rust` with no merged.rs of its own.
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] generated module names with no merged.rs of their own
    def rust_sibling_chapters(root: ROOT)
      modules = generated_modules(root: root)
      rust_domains(root: root)
        .flat_map { |domain| Dir.glob(File.join(domain.dir, "bluebook", "*.bluebook")) }
        .map { |path| Naming.pascal(File.basename(path, ".bluebook")).downcase }
        .uniq
        .select { |name| modules.include?(name) && !generated?(name, root: root) }
    end

    # The regeneration order the drift check runs, sorted by path — so which
    # domain wins Cargo's `default` is derived, not hand-picked.
    #
    # @param root [String] repository root to search under
    # @return [Array<RustDomain>] already-generated Rust domains, in regeneration order
    def rust_regen_order(root: ROOT)
      rust_domains(root: root).select { |domain| generated?(domain.feature, root: root) }
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

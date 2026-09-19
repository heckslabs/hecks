require_relative "fuzzing/target_capabilities"

module Hecks
  # **The corpus, discovered** — every place in this repo that holds a real
  # domain, named once.
  #
  # This used to be spelled out separately by every consumer that walks
  # it — spec/corpus_spec.rb, spec/model_check_spec.rb, bin/model_check,
  # spec/parser_parity_spec.rb, bin/fuzz, Fuzzing::CombinationMiner — and
  # the copies had already drifted: only the model checker saw
  # `qa/bluebook`, only parser parity saw `spec/fixtures`, and nothing but
  # bin/fuzz's own sweep ever saw `qa/stress_domains`. One table here, and
  # each consumer names the KINDS it walks rather than re-deriving where
  # those kinds live.
  #
  # Plain Dir/File only — bin/ scripts require this before (or without)
  # booting anything.
  module Corpus
    ROOT = File.expand_path("../..", __dir__).freeze

    Member = Struct.new(:stem, :kind, :path)

    # **One domain per directory** — its bluebooks sit in `<dir>/bluebook/`
    # or directly in `<dir>` (see `bluebook_files`). Stemmed by directory.
    DIRECTORY_KINDS = {
      example:   "examples/*",
      stress:    "qa/stress_domains/*",
      semantics: "spec/corpus/semantics/domains/*"
    }.freeze

    # **One chapter per file**. Stemmed by the path below the glob's fixed
    # prefix, so a nested fixture keeps its subdirectory (`eras/base`)
    # and never collides with a same-named file elsewhere in the kind.
    FILE_KINDS = {
      grammar:   "lib/hecks/grammar/*.bluebook",
      framework: "lib/hecks/framework/bluebook/*.bluebook",
      qa:        "qa/bluebook/*.bluebook",
      language:  "lib/hecks/language/**/*.bluebook",
      deploy:    "lib/hecks/deploy/bluebook/*.bluebook",
      fixture:   "spec/fixtures/**/*.bluebook"
    }.freeze

    KINDS = (DIRECTORY_KINDS.keys + FILE_KINDS.keys).freeze

    # Where a bluebook the sweep does not boot goes instead. Not a filter:
    # nothing leaves `sweepable_domains` without naming the check that owns
    # it, and spec/corpus_accounting_spec.rb proves each destination exists
    # and actually exercises what is routed to it.
    #
    #   check: :named_in   — `destination` names every routed file
    #                        (`names: :each_file`) or the given text
    #   check: :gitignored — `destination` holds the ignore rule `names`,
    #                        and nothing matching is committed
    #   check: :gap        — no check exercises these yet. Listed so the
    #                        gap is visible; the accounting spec keeps it
    #                        pending and fails the moment one appears.
    #
    # Ordered — a bluebook belongs to the first route it matches, so a
    # specific destination sits above the catch-all for its shape.
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
      # bin/fuzz sweeps it too, once Fuzzing::Replay coerces value-object
      # args before recomputing givens — today its oracle reads raw args
      # while dispatch coerces, so checkout_fixture's VO-reading given
      # reads as wrongly admitted.
      Route.new(%r{\Aspec/fixtures/rust_host/}, :named_in, "rust/host/src/web.rs", "checkout_fixture",
                "the Rust host's checkout fixture, pinned by its web and /api tests")
    ].freeze

    module_function

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

    # What a boot loads for a member: a directory kind's bluebook
    # directory, a file kind's own file. `nil` for a directory holding no
    # bluebook at all.
    def source_of(member)
      DIRECTORY_KINDS.key?(member.kind) ? bluebook_dir(member.path) : member.path
    end

    # Where a domain path keeps its bluebooks — `<domain>/bluebook/*.bluebook`
    # (every example and stress domain), or the directory itself
    # (`qa/bluebook`). `nil` when neither holds a bluebook.
    def bluebook_files(domain_path)
      [File.join(domain_path, "bluebook"), domain_path].each do |dir|
        files = Dir[File.join(dir, "*.bluebook")]
        return files unless files.empty?
      end
      nil
    end

    def bluebook_dir(domain_path)
      files = bluebook_files(domain_path)
      files && File.dirname(files.first)
    end

    # The route a repo-relative path takes instead of the sweep — the
    # first one it matches — or `nil` when the sweep boots it.
    def route_for(relative_path)
      ROUTES.find { |route| route.pattern.match?(relative_path) }
    end

    # What bin/model_check and spec/model_check_spec.rb walk — every kind,
    # less the language (examined as one judged chapter, not file by file)
    # and deploy chapters (the SAM projector's own inputs), and less any
    # member a route already sends to a destination of its own: the
    # broken-on-purpose model_check fixtures must produce their findings
    # there, so a clean-corpus gate here would be the wrong check for them.
    MODEL_CHECK_KINDS = %i[example grammar framework qa stress fixture].freeze

    def model_check_members(root: ROOT)
      members(*MODEL_CHECK_KINDS, root: root).reject { |member| route_for(member.path.delete_prefix("#{root}/")) }
    end

    # **The ledger sweeps itself** — its own chapter is a domain like any
    # other, and the one rotation member that is neither an example nor a
    # stress domain.
    ROTATION_LEDGER = { "quality_control" => "qa/bluebook" }.freeze

    # What the QA rotation is made of — every example and stress domain
    # this repository owns, plus the ledger, as `reference => repo-relative
    # path`: exactly the shape `Target.path` is stored in.
    #
    # Derived, because the hand-kept version silently went stale.
    # `bin/qa_seed_targets` carried a literal list naming three of the
    # thirteen stress domains; the other ten were authored, argued for in
    # their own NOTES.md, several promoted by `bin/qa_generated_domains
    # --promote` — and never swept once, because a `Target` row is what
    # puts a domain in the rotation and nothing tied that list to the
    # corpus. Promotion only ever printed the `target.identify` line for a
    # human to run.
    def rotation_targets(root: ROOT)
      members(:example, :stress, root: root)
        .to_h { |member| [member.stem, member.path.delete_prefix("#{root}/")] }
        .merge(ROTATION_LEDGER)
    end

    # Every bootable domain in the project, not a hand-kept list — any
    # directory holding a `.bluebook` no route sends elsewhere, a
    # `bluebook/` folder standing for the domain directory around it.
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

    # The domain directory a member stands for, spelled the way
    # `sweepable_domains` spells it: a `bluebook/` folder is its parent.
    def domain_dir_of(member)
      dir = File.directory?(member.path) ? member.path : File.dirname(member.path)
      File.basename(dir) == "bluebook" ? File.dirname(dir) : dir
    end

    # ── The Rust-facing corpus ─────────────────────────────────────────
    #
    # Every Rust-facing list (the fuzz bridge, the codegen drift check,
    # rust coverage, codegen parity) used to be typed out by hand, and
    # each had drifted from `rust/Cargo.toml`'s `[features]`: fuzzing saw
    # 8 of 20 features. These read the one source instead. The
    # `rust/src/generated/` modules split into buckets, and
    # spec/corpus_rust_spec.rb proves every Cargo feature and every
    # generated module lands in exactly one of them:
    #
    #   rust_domains       an in-repo domain directory with a Cargo feature
    #                      of its own: fuzzed, regenerated, coverage- and
    #                      parity-checked
    #   framework chapters no feature and no merged.rs; written as a side
    #                      effect of every `uses_framework` domain's regen
    #   RUST_ELSEWHERE     a feature with no in-repo domain directory, and
    #                      the check that owns it instead
    GENERATED_DIR = "rust/src/generated".freeze
    RUST_DOMAIN_KINDS = %i[example stress fixture].freeze

    RustDomain = Struct.new(:feature, :dir, :kind)

    # `check: :named_in` — `destination` must name `names`.
    # `check: :external` — no in-repo domain directory may carry the name;
    #                      the day one does, it belongs in rust_domains.
    Elsewhere = Struct.new(:check, :destination, :names, :why)

    RUST_ELSEWHERE = {
      "meta"       => Elsewhere.new(:named_in, "spec/codegen_parity_spec.rb", "bluebook_language",
                                    "the self-hosted grammar (lib/hecks/language), not a domain directory — every " \
                                    "bin/project_rust run rewrites it (so the drift check diffs it), codegen parity " \
                                    "checks it as bluebook_language, and there is no directory to fuzz"),
      "embryonaut" => Elsewhere.new(:external, "~/Projects/embryonautfoundersapp", "embryonaut",
                                    "an external product's domain — its bluebook, regeneration and parity are owed " \
                                    "by its own repo; here bin/rust_coverage checks only the committed snapshot")
    }.freeze

    # **Shrink-only**. A generated module `bin/rust_coverage` still reports a
    # gap for. `bin/corpus --rust-coverage` requires each of these to
    # still fail, so an entry that starts passing breaks the build until
    # it is deleted here.
    RUST_COVERAGE_PENDING = {}.freeze

    def cargo_features_table(root: ROOT)
      File.read(File.join(root, "rust/Cargo.toml"))[Fuzzing::TargetCapabilities::FEATURES_TABLE] || ""
    end

    def cargo_features(root: ROOT)
      cargo_features_table(root: root).scan(/^(\w+)\s*=\s*\[\]/).flatten
    end

    # The feature `bin/project_rust` last wrote as Cargo's `default`.
    def cargo_default(root: ROOT)
      cargo_features_table(root: root)[/^default\s*=\s*\["(\w+)"\]/, 1]
    end

    # Every in-repo domain directory whose name is a Cargo feature, sorted
    # by path. When the module is already generated, its metadata.rs stamp
    # decides which directory it came from — a directory name alone is not
    # enough: spec/fixtures/qa_discover_external_domains vendors a second
    # `examples/pizzas` that no Cargo feature was ever generated from.
    def rust_domains(root: ROOT)
      features = cargo_features(root: root)
      members(*RUST_DOMAIN_KINDS, root: root)
        .map { |member| [domain_dir_of(member), member.kind] }
        .uniq(&:first)
        .select { |dir, _| rust_domain_dir?(dir, features, root) }
        .sort_by(&:first)
        .map { |dir, kind| RustDomain.new(File.basename(dir).downcase, dir, kind) }
    end

    def rust_domain_dir?(dir, features, root)
      feature = File.basename(dir).downcase
      source = generated_source(feature, root: root)
      features.include?(feature) && (source.nil? || source == dir.delete_prefix("#{root}/"))
    end

    # Where a generated module came from, read off the stamp bin/project_rust
    # writes into its metadata.rs — `examples/pizzas`, `/abs/path/embryonaut`,
    # `the self-hosted language (lib/hecks/language/bluebook)`, with any
    # ` (uses_framework "X")` suffix dropped. `nil` when not generated.
    SOURCE_STAMP = %r{GENERATED by bin/project_rust — (.+?)(?: \(uses_framework "\w+"\))?'s own canonical IR,}

    def generated_source(module_name, root: ROOT)
      metadata = File.join(root, GENERATED_DIR, module_name, "metadata.rs")
      File.file?(metadata) ? File.read(metadata)[SOURCE_STAMP, 1] : nil
    end

    def generated_modules(root: ROOT)
      Dir.children(File.join(root, GENERATED_DIR)).select { |name| File.directory?(File.join(root, GENERATED_DIR, name)) }.sort
    end

    def generated?(feature, root: ROOT)
      File.file?(File.join(root, GENERATED_DIR, feature, "merged.rs"))
    end

    # Framework members `bin/project_rust` writes a module for as a side
    # effect of some `uses_framework` domain — a module, no merged.rs.
    def rust_framework_chapters(root: ROOT)
      modules = generated_modules(root: root)
      members(:framework, root: root).map(&:stem)
                                     .select { |stem| modules.include?(stem) && !generated?(stem, root: root) }
    end

    # The regeneration order the drift check runs. Sorted by path, so
    # which domain runs last — and so wins Cargo's `default`, mod.rs's cfg
    # comments and the shared framework modules' attribution stamp — is a
    # fact of the sorted list, not a hand-picked order. (The old hand list
    # put waybill last; PR #667 moved to the sort, which makes
    # has_many_fixture last.) spec/corpus_rust_spec.rb pins last == default.
    def rust_regen_order(root: ROOT)
      rust_domains(root: root).select { |domain| generated?(domain.feature, root: root) }
    end

    # The chapter a bluebook declares — `Hecks.bluebook "<Name>"`, read
    # off the file rather than guessed from its name (a grammar chapter's
    # file is named after its role, `aggregate.bluebook`, while its
    # chapter is always "Bluebook"). Scans the whole file: a framework
    # member's header comment can run past any fixed line cap.
    def chapter_name_of(bluebook_path)
      bluebook_path = Array(bluebook_path).first
      header = File.foreach(bluebook_path).find { |line| line =~ /\A\s*Hecks\.bluebook\s+"([^"]+)"/ }
      header && Regexp.last_match(1)
    end
  end
end

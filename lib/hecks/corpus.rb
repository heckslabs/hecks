module Hecks
  # THE CORPUS, DISCOVERED — every place in this repo that holds a real
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

    # ONE DOMAIN PER DIRECTORY — its bluebooks sit in `<dir>/bluebook/`
    # or directly in `<dir>` (see `bluebook_files`). Stemmed by directory.
    DIRECTORY_KINDS = {
      example:   "examples/*",
      stress:    "qa/stress_domains/*",
      semantics: "spec/corpus/semantics/domains/*"
    }.freeze

    # ONE CHAPTER PER FILE. Stemmed by the path below the glob's fixed
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

    # WHERE A BLUEBOOK THE SWEEP DOES NOT BOOT GOES INSTEAD. Not a filter:
    # nothing leaves `sweepable_domains` without naming the check that owns
    # it, and spec/corpus_accounting_spec.rb proves each destination exists
    # and actually exercises what is routed to it.
    #
    #   check: :named_in   — `destination` names every routed file
    #                        (`names: :each_file`) or the given text
    #   check: :gitignored — `destination` holds the ignore rule `names`,
    #                        and nothing matching is committed
    #   check: :gap        — NO check exercises these yet. Listed so the
    #                        gap is visible; the accounting spec keeps it
    #                        pending and fails the moment one appears.
    #
    # ORDERED — a bluebook belongs to the FIRST route it matches, so a
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
                "the Rust host's checkout fixture, pinned by its web tests")
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

    # WHERE A DOMAIN PATH KEEPS ITS BLUEBOOKS — `<domain>/bluebook/*.bluebook`
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

    # EVERY BOOTABLE DOMAIN IN THE PROJECT, not a hand-kept list — any
    # directory holding a `.bluebook` no ROUTE sends elsewhere, a
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

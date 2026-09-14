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

    # NOT A DOMAIN, each for a stated reason. Applied by
    # `sweepable_domains`, the "everything bootable" walk; the kinds above
    # are raw enumerations, because parser parity deliberately parses the
    # era and model_check fixtures a boot would refuse.
    EXCLUDED = {
      %r{/\.aws-sam/}                  => "SAM build output — a vendored copy of real sources, not a source",
      %r{\Arust/}                      => "the Rust parser's own test fixtures",
      %r{/data/eras/}                  => "era snapshots a file adapter writes at runtime, never committed",
      %r{/translations/}               => "translation edges — a sub-language, not chapters",
      %r{\Alib/hecks/forms/examples/}  => "a Forms presentation config wearing the .bluebook extension",
      %r{\Aspec/fixtures/eras/}        => "deliberately conflicting versions of one domain, for era comparison",
      %r{\Aspec/fixtures/model_check/} => "domains broken on purpose so the model checker has something to find",
      # Remove once Fuzzing::Replay coerces value-object args before
      # recomputing givens (lib/hecks/fuzzing/replay.rb).
      %r{\Aspec/fixtures/rust_host/}   => "a known false positive in bin/fuzz's own oracle: " \
                                          "lifecycle_guard_and_given_violations_are_refused recomputes givens " \
                                          "with raw args while dispatch coerces value-object attributes first, " \
                                          "so checkout_fixture's VO-reading given reads as wrongly admitted"
    }.freeze

    # Patterns that only ever match files a RUN writes — a clean checkout
    # holds none, so "every exclusion still matches something" skips them.
    RUNTIME_ONLY_EXCLUSIONS = [%r{/\.aws-sam/}, %r{/data/eras/}].freeze

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

    def excluded?(relative_path)
      EXCLUDED.keys.any? { |pattern| pattern.match?(relative_path) }
    end

    # EVERY BOOTABLE DOMAIN IN THE PROJECT, not a hand-kept list — any
    # directory holding a `.bluebook` outside EXCLUDED, a `bluebook/`
    # folder standing for the domain directory around it.
    def sweepable_domains(root = ROOT)
      Dir.chdir(root) do
        Dir.glob("**/*.bluebook")
           .reject { |path| excluded?(path) }
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

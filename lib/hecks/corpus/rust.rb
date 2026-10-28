module Hecks
  module Corpus
    # Every Rust-facing list reads `rust/Cargo.toml`'s `[features]` as its
    # one source, rather than each consumer typing it out by hand.
    GENERATED_DIR = "rust/src/generated".freeze
    RUST_DOMAIN_KINDS = %i[example stress semantics fixture].freeze

    RustDomain = Struct.new(:feature, :dir, :kind)

    # `check: :named_in` — `destination` must name `names`.
    Elsewhere = Struct.new(:check, :destination, :names, :why)

    RUST_ELSEWHERE = {
      "meta" => Elsewhere.new(:named_in, "lib/hecks/tools/regeneration_run.rb", "rust/src/generated",
                              "the self-hosted grammar (lib/hecks/language), not a domain directory — every " \
                              "hecks project_rust run rewrites it, so the drift check diffs it with the rest " \
                              "of rust/src/generated, and there is no directory to fuzz")
    }.freeze

    # **Shrink-only**: a generated module `hecks rust_coverage` still flags.
    # `hecks corpus_rust_coverage --rust-coverage` requires each entry to still fail, so a
    # newly-passing module breaks the build until removed here.
    RUST_COVERAGE_PENDING = {
      "governance" => "the live-grant queries filter on an unset `ends_at`, and a query condition has no " \
                      "null value to compile it to (ADR 0140); the host decides liveness itself until it has"
    }.freeze

    # The stamp hecks project_rust writes into metadata.rs, e.g.
    # `examples/pizzas` or `the self-hosted language (...)`; a chapter's is its own name.
    SOURCE_STAMP = /GENERATED\ by\ hecks\ project_rust\ —\ (.+?)'s\ own\ canonical\ IR,/

    # Raised when a name is not a domain the corpus regenerates; the message lists the valid ones.
    class UnknownDomain < ArgumentError; end

    # The Rust-facing lists: which domains and bluebooks `rust/` carries, read off Cargo's
    # `[features]` and the generated modules rather than typed out by hand. Extended onto
    # `Corpus`.
    module Rust
      # A Cargo feature line with an empty dependency array, capturing the feature's name.
      EMPTY_FEATURE = /^(\w+)\s*=\s*\[\]/

      # Cargo's `default = ["name"]` line, capturing the default feature's name.
      DEFAULT_FEATURE = /^default\s*=\s*\["(\w+)"\]/

      # A hecksagon's `attaches "Name"` line for a gem bluebook (no `from:`), capturing the name.
      ATTACHED_BY_NAME = /^\s*attaches\s+"(\w+)"\s*$/

      # A bluebook file's `Hecks.bluebook "Name"` header, capturing the bluebook's name.
      BLUEBOOK_NAME = /^\s*Hecks\.bluebook\s+"([^"]+)"/

      # The corpus kinds holding bluebooks the gem carries and a hecksagon attaches by name.
      GEM_CHAPTER_KINDS = %i[qa deploy site tickets composer tenancy sme bulk ci_pipeline].freeze

      # Every place a Rust-facing domain's own `attaches` attachment could be declared.
      #
      # @param root [String] repository root to search under
      # @return [String] every reachable hecksagon file's own text, joined by newlines
      def rust_attachment_hecksagon_text(root: ROOT)
        rust_domains(root: root).flat_map { |domain| Dir.glob(File.join(domain.dir, "**", "*.hecksagon")) }
                                .map { |path| File.read(path) }.join("\n")
      end

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
        cargo_features_table(root: root).scan(EMPTY_FEATURE).flatten
      end

      # The feature Cargo's `default` names: the one a corpus run keeps it on.
      #
      # @param root [String] repository root to search under
      # @return [String, nil] the default feature's name, or nil when Cargo.toml
      #   declares none
      def cargo_default(root: ROOT)
        cargo_features_table(root: root)[DEFAULT_FEATURE, 1]
      end

      # Every in-repo domain directory whose name is a Cargo feature, sorted
      # by path — disambiguated by the generated module's metadata.rs stamp when one exists.
      #
      # @param root [String] repository root to search under
      # @return [Array<RustDomain>] each Rust-facing domain, sorted by directory path
      def rust_domains(root: ROOT)
        features = cargo_features(root: root)
        candidates = members(*RUST_DOMAIN_KINDS, root: root).map { |member| [domain_dir_of(member), member.kind] }
                                                            .uniq(&:first)
        candidates.select { |dir, _| rust_domain_dir?(dir, features, root) }
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

      # Bluebooks attached via `kind` that get a generated module as a side
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

      # Names the framework bluebooks Rust carries as modules, beside its domains' own bluebooks.
      #
      # @param root [String] repository root to search under
      # @return [Array<String>] generated module names for the `:framework` corpus members
      def rust_framework_chapters(root: ROOT)
        rust_side_chapters(:framework, root: root)
      end

      # Names the vendored bluebooks Rust carries as modules, beside its domains' own bluebooks.
      #
      # @param root [String] repository root to search under
      # @return [Array<String>] generated module names for the `:vendored` corpus members
      def rust_vendored_chapters(root: ROOT)
        rust_side_chapters(:vendored, root: root)
      end

      # Bluebooks an in-repo Rust domain carries beside its own bluebook,
      # written as a module by `hecks project_rust` with no merged.rs of its own.
      #
      # @param root [String] repository root to search under
      # @return [Array<String>] generated module names with no merged.rs of their own
      def rust_sibling_chapters(root: ROOT)
        modules = generated_modules(root: root)
        names = rust_domains(root: root)
                .flat_map { |domain| Dir.glob(File.join(domain.dir, "bluebook", "*.bluebook")) }
                .map { |path| Naming.pascal(File.basename(path, ".bluebook")).downcase }
        names.uniq.select { |name| modules.include?(name) && !generated?(name, root: root) }
      end

      # Gem bluebooks outside the framework (`FrameworkBluebooks.index`, such as Bulk) that an
      # in-repo Rust
      # domain's hecksagon attaches by name, written as a module by `hecks project_rust` with no
      # merged.rs of their own.
      #
      # @param root [String] repository root to search under
      # @return [Array<String>] generated module names for the attached gem bluebooks
      def rust_attached_chapters(root: ROOT)
        modules = generated_modules(root: root)
        names = rust_attachment_hecksagon_text(root: root).scan(ATTACHED_BY_NAME).flatten & gem_chapter_names(root: root)
        names.map { |name| Naming.pascal(name).downcase }.uniq
             .select { |name| modules.include?(name) && !generated?(name, root: root) }
      end

      # The names the gem's own attachable bluebooks declare in their `Hecks.bluebook` headers.
      #
      # @param root [String] repository root to search under
      # @return [Array<String>] bluebook names, from the files `GEM_CHAPTER_KINDS` hold
      def gem_chapter_names(root: ROOT)
        members(*GEM_CHAPTER_KINDS, root: root).filter_map { |member| File.read(member.path)[BLUEBOOK_NAME, 1] }.uniq
      end

      # The regeneration order the drift check runs, sorted by path, and the domains a corpus
      # run declares to `hecks project_rust`.
      #
      # @param root [String] repository root to search under
      # @return [Array<RustDomain>] every Rust domain with a Cargo feature, in regeneration order:
      #   a fresh checkout has no generated output, so the sources, not the output, name them
      def rust_regen_order(root: ROOT)
        rust_domains(root: root)
      end

      # The named domains of the regeneration order, in that order whatever order they are named in.
      #
      # @param names [Array<String>, nil] feature names; nil names every domain
      # @param root [String] repository root to search under
      # @return [Array<RustDomain>] the named domains, in regeneration order
      # @raise [UnknownDomain] when a name is not a domain's feature, listing the valid ones
      def rust_domains_named(names, root: ROOT)
        order = rust_regen_order(root: root)
        return order if names.nil?

        unknown = names - order.map(&:feature)
        unless unknown.empty?
          raise UnknownDomain, "unknown domain(s) #{unknown.join(", ")}; valid: #{order.map(&:feature).sort.join(", ")}"
        end

        order.select { |domain| names.include?(domain.feature) }
      end
    end
  end
end

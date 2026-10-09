module Hecks
  module Corpus
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

    # **Shrink-only**: a generated module `hecks rust_coverage` still flags.
    # `hecks corpus_rust_coverage --rust-coverage` requires each entry to still fail, so a
    # newly-passing module breaks the build until removed here.
    RUST_COVERAGE_PENDING = {}.freeze

    # The stamp hecks project_rust writes into metadata.rs, e.g.
    # `examples/pizzas` or `the self-hosted language (...)`, with any
    # ` (attaches "X")`/` (attaches "x", from: :vendor)` suffix stripped.
    SOURCE_STAMP = /
      GENERATED\ by\ hecks\ project_rust\ —\ (.+?)
      (?:\ \(attaches\ "\w+"(?:,\ from:\ :vendor)?\))?
      's\ own\ canonical\ IR,
    /x

    # The Rust-facing lists: which domains and chapters `rust/` carries, read off Cargo's
    # `[features]` and the generated modules rather than typed out by hand. Extended onto
    # `Corpus`.
    module Rust
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
      # @return [Array<RustDomain>] every Rust domain with a Cargo feature, in regeneration order:
      #   a fresh checkout has no generated output, so the sources, not the output, name them
      def rust_regen_order(root: ROOT)
        rust_domains(root: root)
      end
    end
  end
end

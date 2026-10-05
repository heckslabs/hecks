# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../../hecks"
require_relative "../bluebook/meta_validator"
require_relative "../ports/persistence/plugins/era"
require_relative "domain_name"
require_relative "write_if_changed"

module Hecks
  module RustBuild
    # Generates Rust source for one domain into the workspace's `src/generated/`, and keeps the
    # workspace's `Cargo.toml` features in step.
    #
    #   ProjectRust.call(["path/to/domain"])
    #
    # `hecks-codegen` is the generator (ADR 0086): this class builds the IR from the live registry
    # and `CodegenRun` runs the binary on it. The Ruby-free path is `hecks-build`, which feeds the
    # same binary from `hecks-parse`.
    #
    # The era plugin is required unconditionally so the generator works for any domain, lineage
    # capable or not; `pg` stays lazy inside it, so nothing here opens a database connection.
    class ProjectRust
      # The optional attachments `rust/host` reads from `ir.json`, each omitted when nothing
      # attached provides it: exporter method, then the key it is written under.
      SEAMS = %i[authorization membership identity newsletter newsletter_issues payments
                 registrations payment_connection].freeze

      # @param argv [Array<String>] the domain's directory
      # @return [Integer] the exit status
      # @raise [Failure] when the domain's name cannot be a Rust module and Cargo feature name
      def self.call(argv)
        domain = argv.first or raise Failure, "usage: hecks project_rust <domain>"
        new(domain).call
      end

      # @param domain [String] the domain's directory
      def initialize(domain)
        @domain = domain
        @mod_name = File.basename(domain)
      end

      # @return [Integer] the exit status
      def call
        validate_name!
        generate
        0
      end

      private

      # The name becomes a directory, a `pub mod` identifier and a Cargo feature, so it is checked
      # before any side effect (the `meta/` directory is rewritten below).
      def validate_name!
        return if DomainName.valid?(@mod_name)

        raise Failure, "hecks project_rust: domain name #{@mod_name.inspect} (from #{@domain.inspect}) can't " \
                       "be used as-is — it has to double as a Rust module identifier and a Cargo feature " \
                       "name, and this one is either not a plain lowercase identifier, is a Rust keyword, " \
                       "or collides with a reserved Cargo.toml key " \
                       "(#{DomainName::CARGO_RESERVED.join(', ')}). " \
                       "Rename the domain directory."
      end

      def generate
        load_registry
        @rust_dir = ENV.fetch("HECKS_RUST_DIR", File.join(RustBuild::ROOT, "rust"))
        @out_root = File.join(@rust_dir, "src/generated")
        FileUtils.mkdir_p(@out_root)
        build_target_ir
        FileUtils.rm_rf(File.join(@out_root, "active"))
        generate_with_codegen
        write_root_mod
        sync_cargo_features
      end

      # `hecks-codegen` is the generator; this process only builds the IR it reads from the live
      # registry, so a domain's persistence, seams, translations and source text reach `ir.json`.
      def generate_with_codegen
        meta = Hecks::Projector::Exporter.call(Hecks::Bluebook::MetaValidator.grammar_registry).fetch("Bluebook")
        vendored = @registry.hecksagons.values.flat_map(&:vendored_packages)
        chapters = (@registry.bluebooks.keys - [@domain_name]).map do |name|
          ir = Hecks::Projector::Exporter.call(@registry).fetch(name)
          CodegenRun::Chapter.new(name.downcase, "#{@domain} (#{attachment(name, vendored)})", json_shaped(ir))
        end
        CodegenRun.new(
          rust_dir: @rust_dir, out_root: @out_root, meta: json_shaped(meta), chapters: chapters,
          target: CodegenRun::Chapter.new(@mod_name, @domain, @ir)
        ).call
      end

      # Round-trips a value through JSON so generators see the string-keyed shape a real `ir.json`
      # carries, never live Ruby symbols.
      def json_shaped(payload) = JSON.parse(JSON.generate(payload), symbolize_names: true)

      # `root:` is the domain's own directory: a domain that declares `attaches ... from: :vendor`
      # resolves its vendored chapters beneath it.
      def load_registry
        @registry = Hecks::Runtime::Registry.new(root: File.expand_path(@domain))
        Hecks.with_registry(@registry) do
          lib = File.expand_path("..", __dir__)
          %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
             adapters/driven/prism.adapter adapters/driven/postgres_era.adapter].each do |file|
            Kernel.load(File.join(lib, file))
          end
          @bluebook_dir = File.join(@domain, "bluebook")
          Hecks::Adapters::Folder.new.load_bluebooks(@bluebook_dir)
          load_siblings
          load_environment
        end
        @domain_name = @registry.bluebooks.keys.first
      end

      # Translation edges, hecksagons (whose `attaches` loads a framework chapter into the
      # same registry) and worlds (whose `default_adapter` binds what a hecksagon leaves out), in
      # the order the language loads them.
      def load_siblings
        Dir[File.join(@bluebook_dir, "translations", "*.bluebook")].each { |file| Kernel.load(file) }
        Dir.glob(File.join(@bluebook_dir, "*.hecksagon")).each { |file| Kernel.load(file) }
        Dir.glob(File.join(@bluebook_dir, "*.world")).each { |file| Kernel.load(file) }
      end

      # Production is the default environment when `environments/production.hecksagon` exists
      # (`rust/host` is the production runtime); `HECKS_PROJECT_ENVIRONMENT` overrides it.
      def load_environment
        environment = ENV.fetch("HECKS_PROJECT_ENVIRONMENT") do
          File.exist?(File.join(@bluebook_dir, "environments", "production.hecksagon")) ? "production" : nil
        end
        return if environment.nil? || environment.empty?

        folder = Hecks::Adapters::Folder.new
        folder.load_each(@bluebook_dir, [File.join("environments", "#{environment}.hecksagon")])
        folder.load_each(@bluebook_dir, [File.join("environments", "#{environment}.world")])
      end

      # The target's IR, with the binding facts that ride beside it (they are not shape facts, so
      # `bluebook.to_h` never mentions them).
      def build_target_ir
        exporter = Hecks::Projector::Exporter
        @ir = json_shaped(exporter.call(@registry).fetch(@domain_name))
        @ir[:lineage] = json_shaped(exporter.lineage(@registry, @domain_name))
        @ir[:persistence] = json_shaped(exporter.persistence(@registry, @domain_name))
        seams = SEAMS.to_h { |seam| [seam, exporter.public_send(seam, @registry, @domain_name)] }
        seams.each { |seam, value| @ir[seam] = json_shaped(value) unless value.empty? }
        if !seams[:membership].empty? && seams[:identity].empty?
          raise Failure, "#{@domain_name} provides membership but not identity — rust/host Google sign-in " \
                         "cannot register or link an identity from ir.json. Attach Identity " \
                         "(`attaches \"Identity\"` plus a sibling Hecks.hecksagon \"Identity\") so the " \
                         "hecksagon, not a deploy-time guess, names the identity verbs."
        end
        add_edges_and_source
      end

      # Edges carry their own precompiled SQL, so a boot-time mint only executes it. Committed
      # approvals sit beside the edges. The source text is verbatim: the era's integrity digest is
      # the SHA256 of it, not of anything re-derived from the parsed IR.
      def add_edges_and_source
        edges = Hecks::Projector::Exporter.translations(@registry).select { |edge| edge[:domain] == @domain_name }
        @ir[:translations] = json_shaped(edges)
        approvals = Hecks::Translation::ApprovalFile.read_all(@bluebook_dir)
        @ir[:approvals] = json_shaped(approvals) unless approvals.empty?
        @ir[:source_text] = Hecks::Runtime::EraCheck.source_text_for(
          @registry.bluebooks.fetch(@domain_name), @bluebook_dir, registry: @registry
        )
      end

      # How the target attached a chapter, across every hecksagon the registry loaded: a chapter a
      # sibling hecksagon vendors in is labelled as vendored.
      def attachment(chapter_name, vendored)
        name = vendored.find { |candidate| Hecks::Naming.pascal(candidate.to_s) == chapter_name }
        name ? "attaches #{name.inspect}, from: :vendor" : "attaches #{chapter_name.inspect}"
      end

      # `src/generated/mod.rs`: every domain ever generated, scanned off disk. A directory is a
      # selectable domain exactly when it carries its own `merged.rs`; a framework chapter has
      # none and is always compiled in.
      def write_root_mod
        all_dirs = Dir.children(@out_root).select { |name| File.directory?(File.join(@out_root, name)) }.sort
        @domains = all_dirs.select { |name| File.exist?(File.join(@out_root, name, "merged.rs")) }
        path = File.join(@out_root, "mod.rs")
        wrote = WriteIfChanged.block(path) do |file|
          RootMod.new(file, all_dirs, @domains, @mod_name).write
        end
        puts(wrote ? "wrote #{path}" : "#{path} unchanged")
      end

      # One Cargo feature per domain on disk (added when missing, never removed), with `default`
      # set to this run's domain so a bare `cargo build` builds it. A feature is inserted right
      # after `default = [...]`, not appended: past `[[bin]]` it would parse into that table.
      def sync_cargo_features
        path = File.join(@rust_dir, "Cargo.toml")
        manifest = File.read(path)
        manifest = manifest.sub(/\A/, FEATURES_HEADER) unless manifest.include?("[features]")
        @domains.each { |name| manifest = add_feature(manifest, name) }
        manifest = manifest.sub(/^default\s*=.*$/, "default = [#{@mod_name.inspect}]")
        # An unchanged manifest is not rewritten: a new mtime makes Cargo rebuild the whole crate.
        if WriteIfChanged.call(path, manifest)
          puts "wrote #{path} (default feature: #{@mod_name})"
        else
          puts "#{path} unchanged (default feature already #{@mod_name})"
        end
      end

      # Checked against the `[features]` table only: `[package]`'s `name` or a `[[bin]]` path can
      # share a word with a domain name.
      def add_feature(manifest, name)
        table = manifest[/^\[features\](?:\n(?!\[).*)*$/] || ""
        return manifest if table =~ /^#{Regexp.escape(name)}\s*=/

        manifest.sub(/^default\s*=.*$/) { "#{Regexp.last_match(0)}\n#{name} = []" }
      end

      FEATURES_HEADER = <<~TOML
        # One feature per generated domain: it selects which domain's own
        # generated::<domain>::merged module `generated::active` re-exports
        # (rust/src/generated/mod.rs). `hecks project_rust` adds a feature when a new domain is
        # generated and never removes one (the domain's own generated/<name>/ directory is the
        # source of truth for whether it exists). `default` tracks the domain generated most
        # recently, so a bare `cargo build` keeps working; any other still-generated domain stays
        # reachable via `--no-default-features --features <name>`.
        [features]
        default = []

      TOML
      private_constant :FEATURES_HEADER
    end
  end
end

require_relative "project_rust/root_mod"
require_relative "project_rust/codegen_run"

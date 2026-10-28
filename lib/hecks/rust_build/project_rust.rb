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
      # @param argv [Array<String>] the domain's directory, then optionally the corpus run's
      #   `Declared` flags
      # @return [Integer] the exit status
      # @raise [Failure] when the domain's name cannot be a Rust module and Cargo feature name
      def self.call(argv)
        declared, rest = Declared.split(argv)
        domain = rest.first or raise Failure, "usage: hecks project_rust <domain>"
        new(domain, declared: declared).call
      end

      # @param domain [String] the domain's directory
      # @param declared [Declared, nil] the corpus's declared domains; nil for a workspace of one's
      #   own, where `mod.rs` and Cargo's features follow the domains on disk and `default` the
      #   domain this run generated
      def initialize(domain, declared: nil)
        @domain = domain
        @mod_name = File.basename(domain)
        @declared = declared
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
                       "(#{DomainName::CARGO_RESERVED.join(", ")}). " \
                       "Rename the domain directory."
      end

      def generate
        loader = DomainLoader.new(@domain).call
        @registry = loader.registry
        @domain_name = loader.domain_name
        prepare_output
        @ir = TargetIr.new(@registry, @domain_name, loader.bluebook_dir).call
        FileUtils.rm_rf(File.join(@out_root, "active"))
        generate_with_codegen
        return puts("mod.rs and Cargo.toml left to a run of the whole corpus (--partial)") if @declared&.partial?

        write_root_mod
        sync_cargo_features
      end

      def prepare_output
        @rust_dir = RustBuild.rust_dir
        @out_root = File.join(@rust_dir, "src/generated")
        FileUtils.mkdir_p(@out_root)
      end

      # `hecks-codegen` is the generator; this process only builds the IR it reads from the live
      # registry, so a domain's persistence, seams, translations and source text reach `ir.json`.
      def generate_with_codegen
        meta = Hecks::Projector::Exporter.call(Hecks::Bluebook::MetaValidator.grammar_registry).fetch("Bluebook")
        CodegenRun.new(
          rust_dir: @rust_dir, out_root: @out_root, meta: TargetIr.json_shaped(meta), chapters: chapters,
          target: CodegenRun::Chapter.new(@mod_name, @domain, @ir)
        ).call
      end

      # A chapter is labelled by its own name: its files read the same whoever attached it, so
      # regenerating one domain never changes what another domain's files contain.
      def chapters
        (@registry.bluebooks.keys - [@domain_name]).map do |name|
          ir = Hecks::Projector::Exporter.call(@registry).fetch(name)
          CodegenRun::Chapter.new(name.downcase, name, TargetIr.json_shaped(ir))
        end
      end

      # The feature `default` points at, and the one `mod.rs` treats as the default: the corpus's
      # fixed one, else the domain this run generated.
      def default_feature = @declared ? @declared.default : @mod_name

      # `src/generated/mod.rs`. A directory is a selectable domain exactly when it carries its own
      # `merged.rs`; a framework bluebook has none and is always compiled in. The domains are
      # scanned off disk, or, for the corpus, taken from its declared list.
      def write_root_mod
        all_dirs = generated_directories
        @domains = domains_among(all_dirs)
        path = File.join(@out_root, "mod.rs")
        wrote = WriteIfChanged.block(path) do |file|
          RootMod.new(file, all_dirs, @domains, default_feature).write
        end
        puts(wrote ? "wrote #{path}" : "#{path} unchanged")
      end

      # Every directory under `src/generated`. Under a declared list, its domains are named even
      # when not generated here yet, and a leftover domain directory it does not declare is dropped.
      def generated_directories
        dirs = Dir.children(@out_root).select { |name| File.directory?(File.join(@out_root, name)) }
        return dirs.sort unless @declared

        chapters = dirs.reject { |name| File.exist?(File.join(@out_root, name, "merged.rs")) }
        (chapters | @declared.domains).sort
      end

      def domains_among(directories)
        return @declared.domains.sort if @declared

        directories.select { |name| File.exist?(File.join(@out_root, name, "merged.rs")) }
      end

      # One Cargo feature per domain (added when missing, never removed), with `default` set to
      # `default_feature` so a bare `cargo build` builds it. A feature is inserted right after
      # `default = [...]`, not appended: past `[[bin]]` it would parse into that table.
      def sync_cargo_features
        path = File.join(@rust_dir, "Cargo.toml")
        manifest = File.read(path)
        manifest = "#{FEATURES_HEADER}#{manifest}" unless manifest.include?("[features]")
        @domains.each { |name| manifest = add_feature(manifest, name) }
        manifest = manifest.sub(DEFAULT_FEATURE, "default = [#{default_feature.inspect}]")
        # An unchanged manifest is not rewritten: a new mtime makes Cargo rebuild the whole crate.
        if WriteIfChanged.call(path, manifest)
          puts "wrote #{path} (default feature: #{default_feature})"
        else
          puts "#{path} unchanged (default feature already #{default_feature})"
        end
      end

      # Checked against the `[features]` table only: `[package]`'s `name` or a `[[bin]]` path can
      # share a word with a domain name.
      def add_feature(manifest, name)
        table = manifest[FEATURES_TABLE] || ""
        return manifest if table =~ /^#{Regexp.escape(name)}\s*=/

        manifest.sub(DEFAULT_FEATURE) { "#{Regexp.last_match(0)}\n#{name} = []" }
      end

      # The `default = [...]` line of a Cargo manifest's `[features]` table.
      DEFAULT_FEATURE = /^default\s*=.*$/
      # The `[features]` table of a Cargo manifest, up to the next table header.
      FEATURES_TABLE = /^\[features\](?:\n(?!\[).*)*$/
      private_constant :DEFAULT_FEATURE, :FEATURES_TABLE
    end
  end
end

require_relative "project_rust/declared"
require_relative "project_rust/features_header"
require_relative "project_rust/root_mod"
require_relative "project_rust/codegen_run"
require_relative "project_rust/domain_loader"
require_relative "project_rust/target_ir"

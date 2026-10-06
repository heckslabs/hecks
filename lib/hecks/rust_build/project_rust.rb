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
        write_root_mod
        sync_cargo_features
      end

      def prepare_output
        @rust_dir = ENV.fetch("HECKS_RUST_DIR", File.join(RustBuild::ROOT, "rust"))
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

      def chapters
        vendored = @registry.hecksagons.values.flat_map(&:vendored_packages)
        (@registry.bluebooks.keys - [@domain_name]).map do |name|
          ir = Hecks::Projector::Exporter.call(@registry).fetch(name)
          label = "#{@domain} (#{attachment(name, vendored)})"
          CodegenRun::Chapter.new(name.downcase, label, TargetIr.json_shaped(ir))
        end
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
require_relative "project_rust/domain_loader"
require_relative "project_rust/target_ir"

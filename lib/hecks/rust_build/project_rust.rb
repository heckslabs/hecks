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
        skip_meta, argv = argv.partition { |arg| arg == Meta::SKIP_FLAG }
        declared, rest = Declared.split(argv)
        domain = rest.first or raise Failure, "usage: hecks project_rust <domain>"
        new(domain, declared: declared, meta: skip_meta.empty?).call
      end

      # @param domain [String] the domain's directory
      # @param declared [Declared, nil] the corpus's declared domains; nil for a workspace of one's
      #   own, where `mod.rs` and Cargo's features follow the domains on disk and `default` the
      #   domain this run generated
      # @param meta [Boolean] whether this run generates `meta`; a corpus run that has done so once
      #   says `Meta::SKIP_FLAG` to each domain
      def initialize(domain, declared: nil, meta: true)
        @domain = domain
        @mod_name = File.basename(domain)
        @declared = declared
        @meta = meta
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

        Manifest.new(@rust_dir, @declared, default_feature).call
      end

      def prepare_output
        @rust_dir = RustBuild.rust_dir
        @out_root = File.join(@rust_dir, "src/generated")
        FileUtils.mkdir_p(@out_root)
      end

      # `hecks-codegen` is the generator; this process only builds the IR it reads from the live
      # registry, so a domain's persistence, seams, translations and source text reach `ir.json`.
      def generate_with_codegen
        CodegenRun.new(
          rust_dir: @rust_dir, out_root: @out_root, meta: (Meta.ir if @meta), declarations: declarations,
          target: CodegenRun::Declaration.new(@mod_name, @domain, @ir)
        ).call
      end

      # A declaration is labelled by its own name: its files read the same whoever attached it, so
      # regenerating one domain never changes what another domain's files contain.
      def declarations
        (@registry.bluebooks.keys - [@domain_name]).map do |name|
          ir = Hecks::Projector::Exporter.call(@registry).fetch(name)
          CodegenRun::Declaration.new(name.downcase, name, TargetIr.json_shaped(ir))
        end
      end

      # The feature `default` points at, and the one `mod.rs` treats as the default: the corpus's
      # fixed one, else the domain this run generated.
      def default_feature = @declared ? @declared.default : @mod_name
    end
  end
end

require_relative "project_rust/declared"
require_relative "project_rust/features_header"
require_relative "project_rust/root_mod"
require_relative "project_rust/codegen_run"
require_relative "project_rust/meta"
require_relative "project_rust/domain_loader"
require_relative "project_rust/target_ir"
require_relative "project_rust/manifest"

# frozen_string_literal: true

require "fileutils"
require "find"
require "hecks/version"

module Hecks
  module Adapters
    # The Rust workspace a build writes into: the checkout's own `rust/` in a hecks checkout, or a
    # copy of the packaged workspace inside the client's project.
    #
    # A build writes generated code and a Cargo feature into the workspace it is given, and Cargo
    # writes `target/` beside it, so an installed gem's files must never be that workspace. The
    # copy is keyed by gem version (`.hecks/rust/<version>/`): a domain built with one release
    # compiles against that release's kernel, and a newer gem gets a fresh copy beside the old.
    #
    # A checkout is a working tree with `hecks.gemspec` beside `lib/`; the package never carries
    # the gemspec, so an install cannot be mistaken for one.
    class RustWorkspace
      # The file whose presence beside `lib/` marks a hecks checkout.
      CHECKOUT_MARKER = "hecks.gemspec"

      # What a copy holds: the workspace manifest, the kernel and every crate a domain build uses.
      PACKAGED = %w[Cargo.toml Cargo.lock project.rb project_rust_pipeline.rb project src codegen parser
                    host build web lsp].freeze

      # Left out of a copy: build output anywhere, the corpus tests, and the corpus domains.
      SKIPPED = lambda do |relative|
        relative.split("/").include?("target") || relative == "tests" || relative == "src/generated"
      end

      # The `[features]` table of a Cargo manifest, up to the next table.
      FEATURES_TABLE = /^\[features\](?:\n(?!\[).*)*/

      # Written into a copy once it is complete, so an interrupted copy is redone, not reused.
      MARKER = ".hecks-workspace"

      # Raised when there is no Rust workspace to build in.
      class Unavailable < StandardError; end

      # @return [String] the gem's root directory (where `lib/` and `rust/` live)
      attr_reader :gem_root

      # @param gem_root [String] the gem's root directory
      # @param project_root [String] the client project a copy is made inside
      # @param version [String] the gem version a copy is keyed by
      def initialize(gem_root: File.expand_path("../../../..", __dir__), project_root: Dir.pwd,
                     version: Hecks::VERSION)
        @gem_root = gem_root
        @project_root = project_root
        @version = version
      end

      # @return [Boolean] whether the gem is a hecks checkout rather than an installed package
      def checkout?
        File.exist?(File.join(@gem_root, CHECKOUT_MARKER)) && Dir.exist?(File.join(@gem_root, "lib"))
      end

      # The workspace builds write into: the checkout's own `rust/`, or the versioned copy, made
      # on first use.
      #
      # @return [String] the workspace directory
      # @raise [Unavailable] if the install carries no Rust workspace to copy
      def directory
        return File.join(@gem_root, "rust") if checkout?

        copy
      end

      # The environment a build child runs with. A checkout keeps its own defaults; a copy points
      # Cargo's output at itself, so nothing is written into the gem.
      #
      # @return [Hash{String => String}] variables to set
      # @raise [Unavailable] if the install carries no Rust workspace to copy
      def environment
        return {} if checkout?

        dir = directory
        { "HECKS_RUST_DIR" => dir, "CARGO_TARGET_DIR" => File.join(dir, "target") }
      end

      private

      def copy
        target = File.join(@project_root, ".hecks", "rust", @version)
        return target if File.exist?(File.join(target, MARKER))

        source = File.join(@gem_root, "rust")
        unless File.exist?(File.join(source, "Cargo.toml"))
          raise Unavailable, "this hecks #{@version} install carries no Rust workspace to build in"
        end

        FileUtils.rm_rf(target)
        FileUtils.mkdir_p(target)
        PACKAGED.each { |entry| copy_entry(source, target, entry) }
        clean_features(File.join(target, "Cargo.toml"))
        File.write(File.join(target, MARKER), "#{@version}\n")
        target
      end

      # The packaged manifest lists a feature per corpus domain, and `default` names one of them.
      # None of those domains is in a copy, so the list starts empty and the generator adds the
      # client's own.
      def clean_features(manifest)
        return unless File.exist?(manifest)

        File.write(manifest, File.read(manifest).sub(FEATURES_TABLE, "[features]\ndefault = []\n"))
      end

      def copy_entry(source, target, entry)
        from = File.join(source, entry)
        return unless File.exist?(from)

        Find.find(from) do |path|
          relative = path.delete_prefix("#{source}/")
          Find.prune if SKIPPED.call(relative)
          destination = File.join(target, relative)
          File.directory?(path) ? FileUtils.mkdir_p(destination) : FileUtils.cp(path, destination)
        end
      end
    end
  end
end

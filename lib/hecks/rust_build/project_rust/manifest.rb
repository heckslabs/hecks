# frozen_string_literal: true

require_relative "../write_if_changed"

module Hecks
  module RustBuild
    class ProjectRust
      # The two files every domain's generation shares: `src/generated/mod.rs` and the workspace's
      # `Cargo.toml` features. A run of one domain writes them after its own files; a corpus run
      # that generates its domains side by side tells each `--partial` and writes them once, here,
      # after the last domain is done, so no two processes ever write them.
      class Manifest
        # The `default = [...]` line of a Cargo manifest's `[features]` table.
        DEFAULT_FEATURE = /^default\s*=.*$/
        # The `[features]` table of a Cargo manifest, up to the next table header.
        FEATURES_TABLE = /^\[features\](?:\n(?!\[).*)*$/

        # @param rust_dir [String] the workspace, which holds `Cargo.toml` and `src/generated`
        # @param declared [Declared, nil] the corpus's declared domains; nil follows the domains on
        #   disk
        # @param default [String] the feature `mod.rs` treats as the default and Cargo's `default`
        #   points at
        def initialize(rust_dir, declared, default)
          @rust_dir = rust_dir
          @out_root = File.join(rust_dir, "src/generated")
          @declared = declared
          @default = default
        end

        # Writes `mod.rs` and syncs Cargo's features, each only when its bytes change.
        #
        # @return [void]
        def call
          write_root_mod
          sync_cargo_features
        end

        private

        # `src/generated/mod.rs`. A directory is a selectable domain exactly when it carries its own
        # `merged.rs`; a framework bluebook has none and is always compiled in. The domains are
        # scanned off disk, or, for the corpus, taken from its declared list.
        def write_root_mod
          all_dirs = generated_directories
          @domains = domains_among(all_dirs)
          path = File.join(@out_root, "mod.rs")
          wrote = WriteIfChanged.block(path) do |file|
            RootMod.new(file, all_dirs, @domains, @default).write
          end
          puts(wrote ? "wrote #{path}" : "#{path} unchanged")
        end

        # Every directory under `src/generated`. Under a declared list, its domains are named
        # even when not generated here yet, and a leftover domain directory it does not declare is
        # dropped.
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
        # the default feature so a bare `cargo build` builds it. A feature is inserted right after
        # `default = [...]`, not appended: past `[[bin]]` it would parse into that table.
        def sync_cargo_features
          path = File.join(@rust_dir, "Cargo.toml")
          manifest = File.read(path)
          manifest = "#{FEATURES_HEADER}#{manifest}" unless manifest.include?("[features]")
          @domains.each { |name| manifest = add_feature(manifest, name) }
          manifest = manifest.sub(DEFAULT_FEATURE, "default = [#{@default.inspect}]")
          # An unchanged manifest is not rewritten: a new mtime makes Cargo rebuild the whole crate.
          return puts("#{path} unchanged (default feature already #{@default})") unless WriteIfChanged.call(path, manifest)

          puts "wrote #{path} (default feature: #{@default})"
        end

        # Checked against the `[features]` table only: `[package]`'s `name` or a `[[bin]]` path can
        # share a word with a domain name.
        def add_feature(manifest, name)
          table = manifest[FEATURES_TABLE] || ""
          return manifest if table =~ /^#{Regexp.escape(name)}\s*=/

          manifest.sub(DEFAULT_FEATURE) { "#{Regexp.last_match(0)}\n#{name} = []" }
        end
      end
    end
  end
end

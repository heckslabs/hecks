# frozen_string_literal: true

require "fileutils"
require "hecks/rust_build/target_dir"

module Hecks
  module Adapters
    class MainIntegration
      # Where a clean copy's crates keep their Cargo output: each crate's `target` in the copy is a
      # link to a directory beside the shared targets the Tickets world's `session_environment`
      # names, one per pinned toolchain and crate, so the second verification finds the
      # dependencies the first one compiled. A spec that runs `cargo build` in a crate and reads
      # `<crate>/target/debug` still finds its binary there, and no `CARGO_TARGET_DIR` is set.
      # Cargo's fingerprints decide what rebuilds: a copy's files are new, so its own crates compile
      # again, and the registry dependencies are reused.
      #
      # Each directory is itself a Cargo target (`debug/` directly below it) whose name matches no
      # worktree slot, so `Build.PruneRust` drops its artifacts unused for `days` and never takes it
      # for an abandoned slot. Verifications take turns (`CopyLock`), so two never write one binary.
      module CargoTarget
        # The directory name's prefix, before the toolchain's channel and the crate's path.
        PREFIX = "verification-"

        # The `channel = "…"` line of a `rust-toolchain.toml`, capturing the channel.
        CHANNEL_LINE = /^\s*channel\s*=\s*"([^"]+)"/

        # The crates a copy holds: every manifest under `rust/`.
        MANIFESTS = "rust/**/Cargo.toml"

        module_function

        # Links each crate's `target` in the copy to its shared directory, making the directory.
        #
        # @param copy [String] the clean copy a verification runs in
        # @return [Array<String>] the directories linked to
        def link(copy)
          crates(copy).filter_map do |crate|
            link = File.join(copy, crate, "target")
            next if File.exist?(link) || File.symlink?(link)

            FileUtils.mkdir_p(target = dir(copy, crate))
            File.symlink(target, link) && target
          end
        end

        # @param copy [String] the clean copy a verification runs in
        # @return [Array<String>] the directory of each crate, relative to the copy
        def crates(copy) = Dir.glob(MANIFESTS, base: copy).map { |manifest| File.dirname(manifest) }

        # @param copy [String] the clean copy a verification runs in
        # @param crate [String] a crate's directory, relative to the copy
        # @return [String] the shared directory of that crate under the toolchain the copy pins
        def dir(copy, crate)
          name = "#{PREFIX}#{channel(copy)}-#{crate.tr("/", "-")}"
          File.join(RustBuild::TargetDir.shared_root(root: copy), name)
        end

        # @param copy [String] the clean copy a verification runs in
        # @return [String] the `channel` of the copy's `rust-toolchain.toml`; `unpinned` when it
        #   names none
        def channel(copy)
          file = File.join(copy, "rust-toolchain.toml")
          found = File.file?(file) && File.read(file)[CHANNEL_LINE, 1]
          found || "unpinned"
        end
      end
    end
  end
end

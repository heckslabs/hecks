require "hecks/rust_build"
require "hecks/rust_build/native_build"

module Hecks
  module Fuzzing
    class RustGapManifest
      # The workspace and feature a pinned conformance binary belongs to, read off its path.
      #
      # A binary is pinned at `<target>/debug/rust-<feature>`, where `<target>` is the workspace's
      # own `target/` or the directory `RustBuild::NativeBuild.target_dir` chose for the build (a
      # worktree's slot below the shared cargo target). Both are accepted, so a worktree run and a
      # CI run read the same manifest for the same binary.
      module PinnedBinary
        SHAPE = %r{\A(?<target>.+)/debug/rust-(?<feature>[a-z0-9_]+)\z}

        module_function

        # @param binary [String] path to a pinned binary
        # @param rust_dir [String, nil] the workspace the binary was built from; when nil, the
        #   parent of a `<target>` named `target`, else `RustBuild.rust_dir`
        # @return [Array(String, String)] the workspace and the feature
        # @raise [ArgumentError] if `binary` is not pinned in a target directory of the workspace
        def resolve(binary, rust_dir: nil)
          match = SHAPE.match(File.expand_path(binary.to_s))
          workspace = match && workspace_of(match[:target], rust_dir)
          refuse!(binary, workspace) unless workspace && target_dirs(workspace).include?(match[:target])

          [workspace, match[:feature]]
        end

        # @param target [String] the directory holding the binary's `debug/`
        # @param rust_dir [String, nil] the workspace a caller named
        # @return [String] the workspace the binary belongs to
        def workspace_of(target, rust_dir)
          return File.expand_path(rust_dir) if rust_dir
          return File.dirname(target) if File.basename(target) == "target"

          File.expand_path(RustBuild.rust_dir)
        end

        # @param rust_dir [String] the workspace
        # @return [Array<String>] the directories a build of `rust_dir` pins its binaries under
        def target_dirs(rust_dir)
          [File.join(rust_dir, "target"), RustBuild::NativeBuild.target_dir(rust_dir)].map { |dir| File.expand_path(dir) }.uniq
        end

        # @param binary [String] the refused path
        # @param rust_dir [String, nil] the workspace it was checked against
        # @raise [ArgumentError] naming the directories a pinned binary is accepted from
        def refuse!(binary, rust_dir)
          accepted = rust_dir ? target_dirs(rust_dir).map { |dir| "#{dir}/debug/rust-<feature>" }.join(" or ") : nil
          raise ArgumentError, "#{binary.inspect} is not a pinned conformance binary " \
                               "(#{accepted || "<target>/debug/rust-<feature>"}) — cannot tell which manifest describes it"
        end
      end
    end
  end
end

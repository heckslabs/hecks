# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require_relative "build_policy"

module Hecks
  module RustBuild
    # Native binaries kept by what built them, so a workspace whose Rust sources are the same as
    # another's takes the binary and compiles nothing.
    #
    # `NativeBuild` builds one binary per generated domain's Cargo feature, and every worktree used
    # to build its own. Most worktrees never touch `rust/`, so their sources are the same bytes as
    # main's. The key is a digest of those bytes (not of their modification times, which differ
    # per checkout), the compiler's version and the feature; a hit is copied into place and a
    # miss is built and then kept. Anything that goes wrong here is a miss: a build never fails
    # for want of its cache. The newest `KEEP` binaries stay.
    #
    # A kept debug binary carries the paths of the checkout that built it in its panic messages;
    # the checks that run it read behaviour, not those paths.
    module BinaryCache
      # How many binaries the cache keeps.
      KEEP = 32

      module_function

      # @param rust_dir [String] the workspace
      # @param feature [String] the Cargo feature
      # @param sources [Array<String>] the Rust sources and manifests the build reads
      # @return [String] the key: a digest of the sources' bytes and the compiler, and the feature
      def key(rust_dir, feature, sources)
        digest = Digest::SHA256.new
        sources.sort.each { |path| digest << path.delete_prefix("#{rust_dir}/") << "\0" << Digest::SHA256.file(path).digest }
        "#{digest.hexdigest[0, 24]}-#{compiler(rust_dir)}-#{feature}"
      end

      # @param key [String] see `key`
      # @param destination [String] where the binary goes when the cache has it
      # @return [Boolean] whether the cache had it and it was copied to +destination+
      def restore(key, destination)
        kept = File.join(directory, key)
        return false unless File.executable?(kept)

        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(kept, destination)
        File.chmod(0o755, destination)
        FileUtils.touch(kept)
        true
      rescue SystemCallError
        false
      end

      # Keeps a copy of a built binary, through a temporary name renamed into place.
      #
      # @param key [String] see `key`
      # @param binary [String] the built binary
      # @return [void]
      def save(key, binary)
        FileUtils.mkdir_p(directory)
        temp = File.join(directory, ".#{key}.#{Process.pid}")
        FileUtils.cp(binary, temp)
        File.chmod(0o755, temp)
        File.rename(temp, File.join(directory, key))
        prune
      rescue SystemCallError
        nil
      end

      # Removes all but the newest `KEEP` binaries.
      #
      # @return [void]
      def prune
        kept = Dir.children(directory).reject { |name| name.start_with?(".") }
        newest = kept.sort_by { |name| -File.mtime(File.join(directory, name)).to_f }
        newest.drop(KEEP).each { |name| FileUtils.rm_f(File.join(directory, name)) }
      rescue SystemCallError
        nil
      end

      # @return [String] the directory the binaries are kept in
      def directory = File.join(BuildPolicy.cache_root, "bin")

      # @param rust_dir [String] the workspace, whose toolchain file picks the compiler
      # @return [String] a short digest of `rustc -vV` there, "unknown" when it cannot be asked
      def compiler(rust_dir)
        @compilers ||= {}
        @compilers[rust_dir] ||= begin
          out, status = Open3.capture2("rustc", "-vV", chdir: rust_dir)
          status.success? ? Digest::SHA256.hexdigest(out)[0, 8] : "unknown"
        rescue SystemCallError
          "unknown"
        end
      end
    end
  end
end

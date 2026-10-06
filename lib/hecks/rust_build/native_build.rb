# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"

module Hecks
  module RustBuild
    # Builds the native binary for one generated domain's Cargo feature, once per workspace.
    #
    # Examples interleave, and alternating `--features` builds forces a full recompile each time,
    # so a built binary is cached per `[rust_dir, feature, sources]`, where `sources` is a digest of
    # the workspace's Rust sources and manifests. Regenerating the domain changes the digest, so the
    # next call rebuilds instead of answering with a stale binary or a stale failure.
    module NativeBuild
      # Raised when a declared feature fails to build; nil is reserved for "feature not declared".
      class BuildFailed < StandardError; end

      @cache = {}

      class << self
        # @return [Hash{Array => String, BuildFailed, nil}] each build's answer, keyed by
        #   `[rust_dir, feature, sources_digest]`
        attr_reader :cache
      end

      module_function

      # Builds the binary for `domain_feature` once per (rust_dir, feature, sources) and
      # memoizes the result.
      #
      # @param domain_feature [String] the Cargo feature, a domain's directory basename
      # @param rust_dir [String] the workspace to build in
      # @return [String, nil] the pinned binary, or nil when Cargo.toml declares no such feature
      # @raise [BuildFailed] when the build fails (memoized too)
      def build_rust_for(domain_feature, rust_dir)
        cache = NativeBuild.cache
        key = [rust_dir, domain_feature, sources_digest(rust_dir)]
        if cache.key?(key)
          raise cache[key] if cache[key].is_a?(BuildFailed)

          return cache[key]
        end

        manifest = File.read(File.join(rust_dir, "Cargo.toml"))
        return cache[key] = nil unless manifest =~ /^#{Regexp.escape(domain_feature)}\s*=\s*\[\]/

        begin
          cache[key] = build_and_pin(domain_feature, rust_dir)
        rescue BuildFailed => e
          cache[key] = e
          raise
        end
      end

      # Fingerprints what a build reads: every `.rs`, `.toml` and `Cargo.lock` file under the
      # workspace outside `target/`, by path, size and modification time.
      #
      # @param rust_dir [String] the workspace
      # @return [String] a hex digest that changes when any of those files does
      def sources_digest(rust_dir)
        digest = Digest::SHA256.new
        Dir.glob(File.join(rust_dir, "**", "*.{rs,toml}"), File::FNM_DOTMATCH).sort.each do |path|
          digest_file(digest, path, rust_dir)
        end
        lock = File.join(rust_dir, "Cargo.lock")
        digest_file(digest, lock, rust_dir) if File.file?(lock)
        digest.hexdigest
      end

      def digest_file(digest, path, rust_dir)
        relative = path.delete_prefix("#{rust_dir}/")
        return if relative.start_with?("target/") || !File.file?(path)

        stat = File.stat(path)
        digest << "#{relative}\0#{stat.size}\0#{stat.mtime.to_i}.#{stat.mtime.nsec}\n"
      end

      # Holds an exclusive flock from `cargo build` through the copy-out: parallel sweeps share
      # `target/debug/rust`, and another build could overwrite it before it is pinned. The lock
      # file is left on disk.
      #
      # @param domain_feature [String] the Cargo feature
      # @param rust_dir [String] the workspace to build in
      # @return [String] the binary, pinned to `target/debug/rust-<feature>`
      # @raise [BuildFailed] when the build fails or leaves no binary
      def build_and_pin(domain_feature, rust_dir)
        lock_path = File.join(rust_dir, "target", ".build_rust_for.lock")
        FileUtils.mkdir_p(File.dirname(lock_path))

        File.open(lock_path, File::CREAT | File::RDWR) do |lock|
          lock.flock(File::LOCK_EX)
          command = ["cargo", "build", "--no-default-features", "--features", domain_feature]
          cargo(command, rust_dir, domain_feature)
          pin(rust_dir, domain_feature, command)
        end
      end

      def cargo(command, rust_dir, domain_feature)
        _stdout, stderr, status = Open3.capture3(*command, chdir: rust_dir)
        return if status.success?

        raise BuildFailed, "`#{command.join(" ")}` failed in #{rust_dir} (exit #{status.exitstatus}) — " \
                           "#{domain_feature} is declared in Cargo.toml, so this is a build failure, " \
                           "not a missing feature:\n#{stderr}"
      rescue SystemCallError => e
        raise BuildFailed, "`#{command.join(" ")}` could not run in #{rust_dir}: #{e.message}"
      end

      # `cargo build` always writes the same path; it is pinned per feature while the lock is held.
      def pin(rust_dir, domain_feature, command)
        binary = File.join(rust_dir, "target", "debug", "rust")
        unless File.executable?(binary)
          raise BuildFailed, "`#{command.join(" ")}` succeeded in #{rust_dir} but left no executable at #{binary}"
        end

        pinned = File.join(rust_dir, "target", "debug", "rust-#{domain_feature}")
        FileUtils.cp(binary, pinned)
        File.chmod(0o755, pinned)
        pinned
      end
    end
  end
end

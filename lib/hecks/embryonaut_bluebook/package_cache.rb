require "digest"
require "fileutils"
require "json"
require "open3"
require_relative "../cache_dir"
require_relative "../vendoring"
require_relative "../vendoring/git_environment"
require_relative "lock"
require_relative "../embryonaut_bluebook"

module Hecks
  module EmbryonautBluebook
    # Resolves a released package by name into the Hecks cache, so a project boots its bluebooks
    # and adapters without a copy in its own tree. The project records each resolved pin in
    # `packages.lock`, and a resolution that disagrees with that record is refused, so a registry
    # change cannot move a project silently.
    module PackageCache
      # The project file that records each package's pin: its version, commit and content digest.
      LOCK_FILE = "packages.lock".freeze

      # A cached package whose files do not match the digest its own `bluebook.lock` records.
      class Tampered < Vendoring::Error; end

      # A resolved pin that differs from the one the project's `packages.lock` already records.
      class Drifted < Vendoring::Error; end

      # Remote registries are cloned as mirrors; a local path is read in place.
      REMOTE = %r{\A(?:https?|ssh|git|file)://|\A[\w.-]+@[\w.-]+:}

      # Resolves one package release to the files a domain boots, fetching it if the cache lacks it.
      #
      # @param name [String] the package name, such as `"thinking"`
      # @param version [String] the release version, `X.Y.Z`
      # @param from [String] a local registry checkout, or a git URL to clone into the cache
      # @param project_lock [String] path to the project's `packages.lock`, created on first use
      # @return [Array<String>] absolute paths of the package's `.bluebook` and `.adapter` files,
      #   sorted
      # @raise [Vendoring::Error] if the registry has no such release, or git fails
      # @raise [Tampered] if a cached package's files do not match its own lock digest
      # @raise [Drifted] if the project's `packages.lock` pins a different version or commit
      def self.resolve(name, version, from:, project_lock:)
        dir = package_dir(name, version)
        EmbryonautBluebook.vendor!(name, from: registry_path(from), root: dir_root(name, version), ref: version) unless cached?(
          dir, version
        )
        lock = verified_lock(dir, name, version)
        record!(project_lock, name, lock)
        Dir.glob(File.join(dir, "bluebook", "*")).select { |path| path.end_with?(".bluebook", ".adapter") }
      end

      # @param name [String] the package name
      # @param version [String] the release version
      # @return [String] the directory that holds the package's vendored files for this version
      def self.package_dir(name, version) = File.join(dir_root(name, version), "vendor", "embryonaut_bluebooks", name)

      # @param name [String] the package name
      # @param version [String] the release version
      # @return [String] the cache root for one package at one version, so versions never collide
      def self.dir_root(name, version) = File.join(CacheDir.path("packages"), "#{name}-#{version}")

      # @param dir [String] the package's vendored directory
      # @param version [String] the release version wanted
      # @return [Boolean] whether the cache already holds that version's pinned files
      def self.cached?(dir, version)
        lock = Lock.read(File.join(dir, "bluebook.lock"))
        !lock.nil? && lock.version == version
      end

      # @param dir [String] the package's vendored directory
      # @param name [String] the package name, for error messages
      # @param version [String] the release version, for error messages
      # @return [Lock] the lock the cached files were pinned under, once their digest is checked
      # @raise [Tampered] if the files' digest differs from the lock's digest
      def self.verified_lock(dir, name, version)
        lock = Lock.read(File.join(dir, "bluebook.lock"))
        actual = Lock.digest_of(File.join(dir, "bluebook"))
        return lock if lock && actual && actual == lock.digest

        raise Tampered, "#{name} #{version} in the cache does not match its bluebook.lock digest; " \
                        "remove #{dir} and resolve again"
      end

      # @param project_lock [String] path to the project's `packages.lock`
      # @param name [String] the package name
      # @param lock [Lock] the pin just resolved
      # @return [void]
      # @raise [Drifted] if the file already records a different version or commit for `name`
      def self.record!(project_lock, name, lock)
        pins = File.file?(project_lock) ? JSON.parse(File.read(project_lock)) : {}
        pin = { "version" => lock.version, "commit" => lock.commit, "digest" => lock.digest }
        refuse_drift!(project_lock, name, pins[name], pin)
        return if pins[name] == pin

        FileUtils.mkdir_p(File.dirname(project_lock))
        File.write(project_lock, "#{JSON.pretty_generate(pins.merge(name => pin).sort.to_h)}\n")
      end

      # @param project_lock [String] path to the project's `packages.lock`, named in the message
      # @param name [String] the package name
      # @param recorded [Hash{String => String}, nil] the pin the project records, or nil when none
      # @param pin [Hash{String => String}] the pin just resolved
      # @return [void]
      # @raise [Drifted] if `recorded` is present and differs from `pin`
      def self.refuse_drift!(project_lock, name, recorded, pin)
        return if recorded.nil? || recorded == pin

        raise Drifted, "#{name} resolved to #{pin["version"]} at #{pin["commit"]}, but #{project_lock} pins " \
                       "#{recorded["version"]} at #{recorded["commit"]}; update the pin deliberately"
      end

      # @param from [String] a local checkout path, or a remote URL
      # @return [String] a directory git can read: `from` itself, or its mirror in the cache
      # @raise [Vendoring::Error] if git cannot clone or update the mirror
      def self.registry_path(from)
        return from unless from.match?(REMOTE)

        dir = File.join(CacheDir.path("registries"), Digest::SHA256.hexdigest(from)[0, 16])
        if File.directory?(dir)
          git!(["-C", dir, "remote", "update", "--prune"])
        else
          FileUtils.mkdir_p(File.dirname(dir))
          git!(["clone", "--mirror", "--quiet", from, dir])
        end
        dir
      end

      # @param args [Array<String>] git arguments, run with the repository pinning variables cleared
      # @return [String] git's standard output
      # @raise [Vendoring::Error] if git exits unsuccessfully
      def self.git!(args)
        out, err, status = Open3.capture3(Vendoring::GitEnvironment.clean, "git", *args)
        raise Vendoring::Error, "git #{args.first} failed: #{err.strip}" unless status.success?

        out
      end
    end
  end
end

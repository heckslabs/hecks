require "etc"
require "fileutils"
require "tmpdir"

module Hecks
  # The one place the runtime's own scratch files live, outside the gem: an
  # installed gem is read-only, and a checkout's `tmp/` isn't this library's to assume.
  #
  # A candidate root is used only if it is private to the current user, since the
  # syntax-boot cache it holds is read back with `Marshal.load`.
  module CacheDir
    module_function

    # The directory a named piece of scratch state lives in.
    #
    # @param name [String] the subdirectory, such as `"storehouse"`
    # @return [String] the absolute path of `name` under the cache root; the
    #   directory itself is created by whoever writes to it
    def path(name)
      File.join(root, name)
    end

    # The cache root, resolved once per process.
    #
    # @return [String] the absolute path of the directory every `path` lives under
    def root
      @root ||= resolve
    end

    # Forgets the resolved root so the next call resolves again.
    #
    # @return [void]
    def reset!
      @root = nil
    end

    # Picks the cache root from the environment.
    #
    # @param env [Hash{String => String}] the environment to read
    #   `XDG_CACHE_HOME` and `HOME` from
    # @param tmpdir [String] the system temp directory
    # @param uid [Integer] the current user id, used in the temp fallback's name
    # @return [String] the absolute path of the first candidate that is a
    #   private directory owned by this user, else a per-process directory
    def resolve(env: ENV, tmpdir: Dir.tmpdir, uid: Process.uid)
      candidates(env, tmpdir, uid).each do |candidate|
        return candidate if private_dir?(candidate)
      end
      Dir.mktmpdir("hecks-", tmpdir)
    rescue StandardError
      File.join(tmpdir, "hecks-#{uid}")
    end

    # The roots to try, most preferred first.
    #
    # @param env [Hash{String => String}] the environment
    # @param tmpdir [String] the system temp directory
    # @param uid [Integer] the current user id
    # @return [Array<String>] absolute candidate paths
    def candidates(env, tmpdir, uid)
      xdg  = env["XDG_CACHE_HOME"].to_s
      home = env["HOME"].to_s
      list = []
      list << File.join(xdg, "hecks") if File.absolute_path?(xdg)
      list << File.join(home, ".cache", "hecks") if File.absolute_path?(home)
      list << File.join(tmpdir, "hecks-#{uid}")
    end
    private_class_method :candidates

    # Creates `dir` if needed and says whether it is private to this user.
    #
    # @param dir [String] the candidate directory
    # @return [Boolean] true when `dir` is a directory owned by this user that
    #   no other user can write to; false on any failure
    def private_dir?(dir)
      FileUtils.mkdir_p(dir, mode: 0o700)
      stat = File.stat(dir)
      stat.directory? && stat.owned? && stat.mode.nobits?(0o022) && File.writable?(dir)
    rescue StandardError
      false
    end
    private_class_method :private_dir?
  end
end

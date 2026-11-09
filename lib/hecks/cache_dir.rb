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

    # Whether the cache root is one that lasts between processes: the user's own cache directory,
    # not the temp-directory fallback, which is new for every process or shared by name. A cache
    # that is only worth keeping where it lasts (compiled Ruby, say) asks this first.
    #
    # @param env [Hash{String => String}] the environment to read `XDG_CACHE_HOME` and `HOME` from
    # @return [Boolean]
    def stable?(env: ENV)
      homes = [env["XDG_CACHE_HOME"], File.join(env["HOME"].to_s, ".cache")]
      homes.select { |home| File.absolute_path?(home.to_s) }.map { |home| File.join(home, "hecks") }.include?(root)
    end

    # The directory the gem ships prebuilt cache files in, beside `lib/` so the digest of `lib/`
    # that names a cache file never covers the files built from it. It exists only in a packaged
    # gem, and it is part of the gem's own code, so it needs no ownership check.
    #
    # @param name [String] the file name inside it
    # @return [String] the absolute path of `name` under the gem's `prebuilt/`
    def prebuilt(name)
      File.join(File.expand_path("../..", __dir__), "prebuilt", name)
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
    # @param tmpdir [String, nil] the system temp directory, asked of the system when nil and
    #   needed (the user's own cache directory is tried first and usually serves)
    # @param uid [Integer] the current user id, used in the temp fallback's name
    # @return [String] the absolute path of the first candidate that is a
    #   private directory owned by this user, else a per-process directory
    def resolve(env: ENV, tmpdir: nil, uid: Process.uid)
      found = candidates(env).find { |candidate| private_dir?(candidate) }
      found || fallback(tmpdir || system_tmpdir, uid)
    rescue StandardError
      File.join(tmpdir || system_tmpdir, "hecks-#{uid}")
    end

    # The roots to try first, most preferred first.
    #
    # @param env [Hash{String => String}] the environment
    # @return [Array<String>] absolute candidate paths
    def candidates(env)
      xdg  = env["XDG_CACHE_HOME"].to_s
      home = env["HOME"].to_s
      list = []
      list << File.join(xdg, "hecks") if File.absolute_path?(xdg)
      list << File.join(home, ".cache", "hecks") if File.absolute_path?(home)
      list
    end
    private_class_method :candidates

    # The roots the temp directory offers: one named for the user when it is private, else a
    # directory new to this process.
    #
    # @param tmpdir [String] the system temp directory
    # @param uid [Integer] the current user id
    # @return [String] an absolute path
    def fallback(tmpdir, uid)
      shared = File.join(tmpdir, "hecks-#{uid}")
      return shared if private_dir?(shared)

      Dir.mktmpdir("hecks-", tmpdir)
    end
    private_class_method :fallback

    # @return [String] the system temp directory, which loads `tmpdir` only now that it is needed
    def system_tmpdir
      require "tmpdir"
      Dir.tmpdir
    end
    private_class_method :system_tmpdir

    # Creates `dir` if needed and says whether it is private to this user.
    #
    # @param dir [String] the candidate directory
    # @return [Boolean] true when `dir` is a directory owned by this user that
    #   no other user can write to; false on any failure
    def private_dir?(dir)
      make(dir)
      stat = File.stat(dir)
      stat.directory? && stat.owned? && stat.mode.nobits?(0o022) && File.writable?(dir)
    rescue StandardError
      false
    end
    private_class_method :private_dir?

    # Makes `dir` with the mode only its owner may use, and its parents when it needs them. The
    # common case, a directory that is already there, takes one system call and loads nothing.
    #
    # @param dir [String] the directory
    # @return [void]
    def make(dir)
      Dir.mkdir(dir, 0o700)
    rescue Errno::EEXIST
      nil
    rescue Errno::ENOENT
      require "fileutils"
      FileUtils.mkdir_p(dir, mode: 0o700)
    end
    private_class_method :make
  end
end

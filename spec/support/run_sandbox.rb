require "etc"
require "fileutils"
require "tmpdir"

# Gives every spec run its own home, temporary directory and cache, so a run starts clean and
# cannot read what another run, a dev session or the owner left behind. One root is made per
# process; each run arms it empty and disarms it when it ends, putting the variables back, so a
# resident that runs many suites in one process never carries state from one to the next.
#
# It loads before `hecks` does: constants that expand `~` or `Dir.home` at load then land inside
# the root. The owner's real home stays reachable as {.real_home} for the guards that name live
# state, and the toolchain variables a child needs (cargo, rustup, gems, bundler) are pinned to
# their real values before `HOME` moves. A git started inside the sandbox never climbs out of it
# (`GIT_CEILING_DIRECTORIES`), so a spec that forgot its own `git init` cannot find a checkout's
# history. Runs are armed one at a time: the variables are the process's, so two runs in parallel
# threads would corrupt each other.
module RunSandbox
  # The sub-directories of the root, each emptied when a run arms it.
  PARTS = %w[home tmp cache dev mint verdict-cache event-tap].freeze

  # Gem variables a child reads, pinned to this process's gems.
  PINNED = %w[GEM_HOME GEM_PATH].freeze

  @saved = nil

  class << self
    # @return [String] the owner's home, whatever `HOME` says now
    def real_home = @real_home ||= Etc.getpwuid.dir

    # @return [String] the root of this process's sandbox
    def root
      @root ||= Dir.mktmpdir("hecks-spec-run").tap { |dir| at_exit { retire(dir) } }
    end

    # @param part [String] one of the sandbox's parts
    # @return [String] that part's directory
    def path(part) = File.join(root, part)

    # @return [Boolean] whether a run holds the sandbox now
    def armed? = !@saved.nil?

    # Empties the sandbox and points the process's variables into it. A no-op while armed.
    #
    # @return [void]
    def arm!
      return if armed?

      real_home
      @saved = ENV.to_h
      PARTS.each { |part| reset(path(part)) }
      pin!
      variables.each { |name, value| ENV[name] = value }
    end

    # Puts the variables back to what they were when the run was armed.
    #
    # @return [void]
    def disarm!
      return unless armed?

      (variables.keys + pins.keys + PINNED).uniq.each { |name| restore(name) }
      @saved = nil
    end

    # @param path [String] a path
    # @return [Boolean] whether it lies in this process's sandbox, symlinks resolved
    def inside?(path)
      real = File.realpath(root)
      File.expand_path(path.to_s).start_with?("#{root}/", "#{real}/")
    end

    private

    def variables
      { "HOME"                    => path("home"),
        "TMPDIR"                  => path("tmp"),
        "XDG_CACHE_HOME"          => path("cache"),
        "HECKS_CACHE_DIR"         => path("cache"),
        "HECKS_DEV_STATE"         => path("dev"),
        "HECKS_MINT_STATE"        => path("mint"),
        "HECKS_EVENT_TAP"         => File.join(path("event-tap"), "events.jsonl"),
        "GIT_CEILING_DIRECTORIES" => root }
    end

    def pin!
      pins.each { |name, value| ENV[name] ||= value }
      ENV["GEM_HOME"] = Gem.dir
      ENV["GEM_PATH"] = Gem.path.join(File::PATH_SEPARATOR)
    end

    def pins
      { "CARGO_HOME" => File.join(real_home, ".cargo"), "RUSTUP_HOME" => File.join(real_home, ".rustup"),
        "BUNDLE_USER_CONFIG" => File.join(real_home, ".bundle", "config"),
        "BUNDLE_USER_CACHE" => File.join(real_home, ".bundle", "cache"),
        "BUNDLE_USER_PLUGIN" => File.join(real_home, ".bundle", "plugin") }
    end

    def restore(name)
      @saved.key?(name) ? ENV[name] = @saved[name] : ENV.delete(name)
    end

    def reset(dir)
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
    end

    def retire(dir) = FileUtils.rm_rf(dir)
  end

  # Prepended to the RSpec runner, so every run after the first arms the sandbox and disarms it.
  module Run
    def run(*)
      RunSandbox.arm!
      super
    ensure
      RunSandbox.disarm!
    end
  end
end

RunSandbox.arm!
RSpec::Core::Runner.singleton_class.prepend(RunSandbox::Run) if defined?(RSpec::Core::Runner)
RSpec.configure { |config| config.after(:suite) { RunSandbox.disarm! } } if defined?(RSpec)

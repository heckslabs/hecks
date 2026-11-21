require "open3"
require "tmpdir"
require "fileutils"
require "digest"
require "hecks/adapters/driving/resident/paths"
require_relative "thread_parking"
require_relative "child_process_guard"
require_relative "resident_autopsy"

# Runs this checkout's `exe/hecks` against a resident of its own, in cache directories that
# belong to the example group, so a spec never reaches a developer's resident or their usage
# log. Every resident a group starts is stopped when the group ends.
#
# The checkout is shared by every spec process on the machine, the parallel ones of a CI shard
# among them, and a resident retires when the checkout's code looks changed. So an example tagged
# `:changes_checkout` holds the checkout alone, and every other example of these groups shares
# it: a change made to retire one group's resident never retires another's in the middle of an
# example that needs it standing.
module ResidentLaunch
  include ResidentAutopsy

  ROOT = File.expand_path("../..", __dir__)
  PATHS = Hecks::Adapters::Driving::Resident::Paths
  # Seconds a resident gets to load the Hecks domain and start listening on a cold cache.
  STARTUP = 120
  # The file every spec process of this checkout locks around an example of these groups. It
  # sits outside the checkout, since a new entry at the checkout's root retires a resident too.
  CHECKOUT_LOCK = File.join(Dir.tmpdir, "hecks-spec-checkout-#{Digest::SHA256.hexdigest(ROOT)[0, 12]}.lock")

  # What a launcher line answered: standard output, standard error and the exit status.
  Answer = Struct.new(:out, :err, :status)

  # The group's cache directory is also this process's, so `Paths` finds the launchers' files.
  # Each example holds the checkout, alone when it is tagged `:changes_checkout`.
  def self.included(group)
    group.before(:all) { take_own_cache }
    group.after(:all) { leave_own_cache }
    group.around { |example| holding_the_checkout(alone: example.metadata[:changes_checkout]) { example.run } }
  end

  def take_own_cache
    @cache = Dir.mktmpdir("hr")
    @saved_cache = ENV.fetch("HECKS_CACHE_DIR", nil)
    ENV["HECKS_CACHE_DIR"] = @cache
  end

  # Stops the group's resident, then puts the cache directory back and removes the group's own.
  def leave_own_cache
    stop_resident
    ENV["HECKS_CACHE_DIR"] = @saved_cache
    FileUtils.rm_rf(@cache)
  end

  # Runs the block holding the checkout: alone when `alone`, else shared with the other examples
  # that only need their residents left standing.
  def holding_the_checkout(alone:)
    File.open(CHECKOUT_LOCK, File::CREAT | File::RDWR, 0o600) do |lock|
      lock.flock(alone ? File::LOCK_EX : File::LOCK_SH)
      yield
    end
  end

  # @return [Answer] the line as `exe/hecks` answers it, through a resident unless `resident:`
  #   is false
  def launch(*argv, resident: true)
    out, err, status = Open3.capture3(env(resident), File.join(ROOT, "exe/hecks"), *argv, chdir: ROOT)
    Answer.new(out, err, status.exitstatus)
  end

  # The variables a `bundle exec` puts in the environment, which a plain terminal does not have. A
  # resident starts without them (`Resident::SpawnEnv`), so a launcher that carried them would be
  # refused on them.
  BUNDLER = %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH].freeze

  # The variables the run's sandbox sets that a plain terminal does not have, for the same reason.
  SANDBOXED = %w[HECKS_DEV_STATE GIT_CEILING_DIRECTORIES].freeze

  # @return [Hash] the environment of a launcher started by this group, as a plain terminal would
  #   make it: the specs' own variable that keeps launchers off residents is unset for it, and so
  #   is whatever Bundler put in this process's environment
  def env(resident)
    plain = (BUNDLER + SANDBOXED + ENV.keys.grep(/\ABUNDLE/)).to_h { |name| [name, nil] }
    plain.merge("HECKS_NO_RESIDENT" => (resident ? nil : "1"), "HECKS_CACHE_DIR" => @cache,
                "HOME" => RunSandbox.real_home,
                "XDG_CACHE_HOME" => @cache, "HECKS_USAGE" => "off")
  end

  # @return [Integer, nil] the resident's process id, when its pid file names a live process
  def resident_pid
    pid = Integer(File.read(PATHS.pid(ROOT)).strip)
    Process.kill(0, pid)
    pid
  rescue SystemCallError, ArgumentError
    nil
  end

  # Waits until a resident stands, and answers its process id.
  def wait_for_resident
    ThreadParking.wait_for(timeout: STARTUP) { resident_pid }
    ChildProcessGuard.watch(resident_pid)
  end

  # Waits until a resident other than `old` stands, and answers its process id.
  def wait_for_new_resident(old)
    ThreadParking.wait_for(timeout: STARTUP) { resident_pid && resident_pid != old }
    ChildProcessGuard.watch(resident_pid)
  end

  # Stops the resident and the lines it forked, and clears its files, so a launch finds none.
  def stop_resident
    pid = resident_pid
    ProcessTree.end_tree(pid) if pid
    ThreadParking.wait_for { resident_pid.nil? } if pid
    FileUtils.rm_f([PATHS.socket(ROOT), PATHS.pid(ROOT)])
  end

  # Starts a resident with one cold launch and waits for it.
  def start_resident
    stop_resident
    launch("--help")
    wait_for_resident
  end

  # @return [Float] seconds one launch takes
  def timed(*argv, resident: true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    launch(*argv, resident: resident)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # Runs the block with the checkout's lockfile looking newer, then puts its modification time back.
  # Only an example tagged `:changes_checkout` may call it.
  def with_newer_lockfile
    lockfile = File.join(ROOT, "Gemfile.lock")
    stamp = File.mtime(lockfile)
    File.utime(Time.now + 30, Time.now + 30, lockfile)
    yield
  ensure
    File.utime(stamp, stamp, lockfile)
  end
end

require "open3"
require "tmpdir"
require "fileutils"
require "hecks/adapters/driving/resident/paths"
require_relative "thread_parking"

# Runs this checkout's `exe/hecks` against a resident of its own, in cache directories that
# belong to the example group, so a spec never reaches a developer's resident or their usage
# log. Every resident a group starts is stopped when the group ends.
module ResidentLaunch
  ROOT = File.expand_path("../..", __dir__)
  PATHS = Hecks::Adapters::Driving::Resident::Paths
  # Seconds a resident gets to load the Hecks domain and start listening on a cold cache.
  STARTUP = 120

  # What a launcher line answered: standard output, standard error and the exit status.
  Answer = Struct.new(:out, :err, :status)

  # The group's cache directory is also this process's, so `Paths` finds the launchers' files.
  def self.included(group)
    group.before(:all) do
      @cache = Dir.mktmpdir("hr")
      @saved_cache = ENV.fetch("HECKS_CACHE_DIR", nil)
      ENV["HECKS_CACHE_DIR"] = @cache
    end
    group.after(:all) do
      stop_resident
      ENV["HECKS_CACHE_DIR"] = @saved_cache
      FileUtils.rm_rf(@cache)
    end
  end

  # @return [Answer] the line as `exe/hecks` answers it, through a resident unless `resident:`
  #   is false
  def launch(*argv, resident: true)
    out, err, status = Open3.capture3(env(resident), File.join(ROOT, "exe/hecks"), *argv, chdir: ROOT)
    Answer.new(out, err, status.exitstatus)
  end

  # @return [Hash] the environment of a launcher started by this group; the specs' own variable that
  #   keeps launchers off residents is unset for it
  def env(resident)
    { "HECKS_NO_RESIDENT" => (resident ? nil : "1"), "HECKS_CACHE_DIR" => @cache, "XDG_CACHE_HOME" => @cache,
      "HECKS_USAGE" => "off" }
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
    resident_pid
  end

  # Waits until a resident other than `old` stands, and answers its process id.
  def wait_for_new_resident(old)
    ThreadParking.wait_for(timeout: STARTUP) { resident_pid && resident_pid != old }
    resident_pid
  end

  # Stops the resident and clears its files, so the next launch finds none.
  def stop_resident
    pid = resident_pid
    Process.kill("KILL", pid) if pid
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
  def with_newer_lockfile
    lockfile = File.join(ROOT, "Gemfile.lock")
    stamp = File.mtime(lockfile)
    File.utime(Time.now + 30, Time.now + 30, lockfile)
    yield
  ensure
    File.utime(stamp, stamp, lockfile)
  end
end

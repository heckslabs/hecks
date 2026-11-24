require "json"

# Says why a resident a spec expected to stand is gone, from what the group's own cache directory
# holds. A resident's output goes nowhere and its exit status is its launcher's to read, so what
# is left to name is the files it keeps, the usage log its callers wrote and how long each launch
# took, which tells a slow runner from a resident that was ended. Everything is read only when an
# expectation has already failed, and a missing file reads as absent.
module ResidentAutopsy
  # Notes how many seconds the block's launch took, for {#why_ended}.
  #
  # @return [Object] what the block answered
  def clocked
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    (@launch_seconds ||= []) << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
  end

  # @param pid [Integer] the resident that was to stand
  # @return [String] what the cache directory says about it, for a failure message
  def why_ended(pid)
    ["resident #{pid} is gone", "launch seconds #{(@launch_seconds || []).inspect}",
     "files #{kept_files.inspect}", "baseline #{read_kept(ResidentLaunch::PATHS.baseline(ResidentLaunch::ROOT)).inspect}",
     "usage log tail #{usage_tail.inspect}"].join("; ")
  end

  # @return [String] what the cache directory says when no resident stood in time, for a failure
  #   message: whether one holds the lock, what the pid file names and what the launches left
  def why_not_standing
    ["no resident stood", "lock held #{lock_held?.inspect}",
     "pid file #{read_kept(ResidentLaunch::PATHS.pid(ResidentLaunch::ROOT)).inspect}",
     "launch seconds #{(@launch_seconds || []).inspect}", "files #{kept_files.inspect}",
     "usage log tail #{usage_tail.inspect}"].join("; ")
  end

  # Waits up to the startup time for the block, and says why no resident stood when it never
  # answers.
  #
  # @raise [ThreadParking::NeverReached] with {#why_not_standing} appended
  def waiting_for_one(&)
    ThreadParking.wait_for(timeout: ResidentLaunch::STARTUP, &)
  rescue ThreadParking::NeverReached => e
    raise e.class, "#{e.message}; #{why_not_standing}"
  end

  private

  def kept_files = Dir.children(@cache).sort.map { |name| name.sub(/\A\h{8}-p\d+/, "") }

  def read_kept(path)
    File.read(path).strip
  rescue SystemCallError
    nil
  end

  def usage_tail = read_kept(File.join(@cache, "usage.jsonl")).to_s.lines.last(4).map { |line| line.strip[0, 200] }
end

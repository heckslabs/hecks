# Lets a spec wait on the thing it cares about instead of sleeping a guessed time.
#
#   waiter = Thread.new { lock.synchronize { work } }
#   ThreadParking.wait_until_parked(waiter)
#   expect(waiter).to be_alive   # parked on the lock, not merely slow to start
module ThreadParking
  # Raised when the thing a spec waits for does not happen within the timeout.
  class NeverReached < StandardError; end

  # A queue nobody pushes to, so a timed pop is a bounded wait that is not a `sleep` call.
  TICK = Queue.new
  private_constant :TICK

  module_function

  # Waits until the thread is blocked (on a lock, a queue or I/O) or has finished.
  #
  # @param thread [Thread] the thread expected to block
  # @param timeout [Numeric] seconds to wait before giving up
  # @return [Thread] the thread, now parked or finished
  # @raise [NeverReached] when it keeps running past the timeout
  def wait_until_parked(thread, timeout: 5)
    wait_for(timeout: timeout) { !thread.alive? || thread.status == "sleep" }
    thread
  end

  # Waits until the block answers truthy.
  #
  # @param timeout [Numeric] seconds to wait before giving up
  # @yieldreturn [Boolean] whether the awaited state has been reached
  # @return [void]
  # @raise [NeverReached] when the block never answers truthy within the timeout
  def wait_for(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise NeverReached, "not reached within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      TICK.pop(timeout: 0.005)
    end
  end

  # Lets time pass on purpose: simulated slow work or a poll interval, not a guess about how
  # long another thread needs.
  #
  # @param seconds [Numeric] how long to let pass
  # @return [void]
  def elapse(seconds)
    TICK.pop(timeout: seconds)
  end
end

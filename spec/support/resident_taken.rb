# Waits on what a resident keeps of the callers it has taken, so a spec that leaves a resident too
# slow to answer in time lets it take each caller before the next line asks, and never guesses a
# delay. Mixed into the groups of {ResidentLaunch}.
module ResidentTaken
  # Launches the line until the resident is too slow for it, then waits until the resident has
  # taken the caller the launcher left, the state a launcher reads before it judges a resident that
  # answered too slowly to be stuck. A launcher reads a word the resident has already sent before
  # it waits at all, so on a loaded machine, where the launcher can be held between sending its
  # line and reading, a resident given no time still answers some lines; such a line is served,
  # leaves no `busy` behind, and is launched again.
  #
  # @raise [ThreadParking::NeverReached] when no launch finds the resident too slow, or the
  #   resident never takes the caller
  # @return [Answer] the answer of the line the resident was too slow for
  def launch_until_taken(*argv)
    answer = nil
    ThreadParking.wait_for(timeout: taken_within) { (answer = launch(*argv)) && busy_noted? }
    ThreadParking.wait_for(timeout: taken_within) { taken_since_busy? }
    answer
  end

  # @return [Numeric] seconds a resident has to be found too slow, and then to take the caller
  def taken_within = ResidentLaunch::STARTUP

  # @return [Boolean] whether the latest line found the resident too slow: a launcher notes a
  #   `busy` then, and forgets it when the resident answers
  def busy_noted? = File.exist?(ResidentLaunch::PATHS.busy(ResidentLaunch::ROOT))

  # @return [Boolean] whether the resident took a caller after the latest line it was too slow for
  def taken_since_busy?
    paths = ResidentLaunch::PATHS
    root = ResidentLaunch::ROOT
    File.mtime(paths.taken(root)) >= File.mtime(paths.busy(root))
  rescue SystemCallError
    false
  end
end

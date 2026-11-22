# Waits on what a resident keeps of the callers it has taken, so a spec that leaves a resident too
# slow to answer in time lets it take each caller before the next line asks, and never guesses a
# delay. Mixed into the groups of {ResidentLaunch}.
module ResidentTaken
  # Launches the line, then waits until the resident has taken the caller the launcher left, the
  # state a launcher reads before it judges a resident that answered too slowly to be stuck.
  #
  # @raise [ThreadParking::NeverReached] when the resident never takes the caller
  # @return [Answer] the line's answer
  def launch_until_taken(*argv)
    answer = launch(*argv)
    ThreadParking.wait_for(timeout: ResidentLaunch::STARTUP) { taken_since_busy? }
    answer
  end

  # @return [Boolean] whether the resident took a caller after the latest line it was too slow for
  def taken_since_busy?
    paths = ResidentLaunch::PATHS
    root = ResidentLaunch::ROOT
    File.mtime(paths.taken(root)) >= File.mtime(paths.busy(root))
  rescue SystemCallError
    false
  end
end

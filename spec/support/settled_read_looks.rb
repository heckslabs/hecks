require_relative "stall_settled_looks"

# A train boarding queued with its commit linked, and a Watching adapter whose git read answers
# from `merged`, the commits the spec says are on origin/main.
module SettledReadLooks
  include StallSettledLooks

  def watching
    aggregate = registry.bluebook("Hecks").aggregate("StallWatch")
    Hecks::Adapters::StallWatching.new(registry: registry, aggregate: aggregate, tap: tap,
                                       origin: ->(sha) { merged.include?(sha) })
  end

  def queue = append("BoardingQueued", run, "Hecks::SendTrain", 100, { boarded: "b97ceff" })

  def file_stall = append("StallFiled", "stall-train-unmerged-#{run}", "Hecks::Stall", 50)

  def abandoned_reasons = watching.abandoned(run: "look").map { |row| row[:reason] }
end

require "json"

# Tap lines of the machine's load: each crossing is keyed by the beat that heard it, so a rise and
# the fall after it carry different ids.
module LoadStallLooks
  # @param rows [Array<Array(String, String, Integer)>] each event, its beat and its minutes ago
  def write_load_tap(*rows)
    lines = rows.each_with_index.map do |(event, beat, ago), seq|
      line(seq + 1, event, beat, ago).merge(aggregate: "Hecks::Machine")
    end
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def watching
    aggregate = registry.bluebook("Hecks").aggregate("StallWatch")
    Hecks::Adapters::StallWatching.new(registry: registry, aggregate: aggregate, tap: tap, processes: process_classes)
  end

  def filed = keys("Hecks", "Stall", :stall)
end

require "securerandom"
require "hecks/fuzzing/outside_world"

# Hecks booted once in Memory for the red episode specs, with every port refused, so no flag is
# raised and no revert made: episodes are decided with the times the examples name, and the push
# train's and the red flag's events are reacted to as the event pump would. The boot is shared, so
# an example keys its episodes by its own prefix and begins later than every example before it.
module RedEpisodeHelpers
  class << self
    # @return [Hecks::Runtime::Dispatcher] the one booted Hecks the examples share
    def hecks = @hecks ||= InMemoryDomain.boot_hecks_in_memory

    # @return [Integer] an epoch second a thousand past the one the last example was given
    def next_epoch = @epoch = (@epoch || 0) + 1000
  end

  def epoch = @epoch ||= RedEpisodeHelpers.next_epoch

  def key(run) = "#{@prefix ||= SecureRandom.hex(4)}-#{run}"

  def value(held) = { value: held }

  # Decides one episode with `verb` (`Revert`, `Park`, `Acquit` or `Unfound`), `at` seconds
  # into the example.
  #
  # @return [Object] the decided episode
  def decide(verb, run, at:, **facts)
    RedEpisodeHelpers.hecks.dispatch_flat("Hecks::RedEpisode.#{verb}", run: value(key(run)), base: "b0",
                                                                        now: value(epoch + at), **facts)
  end

  def reverting(run, at:)
    decide("Revert", run, at: at, culprit: "m-#{run}", branch: "feature-#{run}", work: "feature-#{run}")
  end

  def parked(run, at:) = decide("Park", run, at: at, culprit: "m-#{run}")

  def unfound(run, at:) = decide("Unfound", run, at: at, landed: "l-#{run}")

  def acquitted(run, at:) = decide("Acquit", run, at: at)

  # Reacts to one event of `aggregate` keyed `id`, as the event pump would.
  #
  # @return [Array<Hash>] one record per policy that heard it
  def hear(name, aggregate, id, payload)
    hecks = RedEpisodeHelpers.hecks
    event = Hecks::Runtime::Event.new(name: name, aggregate: "Hecks::#{aggregate}", id: id, payload: payload,
                                      occurred_at: Hecks::Runtime::Event.stamp)
    Hecks::Runtime::PolicyInterpreter.new(hecks.registry, dispatcher: hecks).react(event, "Hecks")
  end

  # The push train reverted the culprit of episode `run`: its revert is keyed by that run.
  #
  # @return [Array<Hash>] one record per policy that heard it
  def landing_reverted(run, local: false)
    hear("LandingReverted", "SendTrain", key(run), { reverted: value("r-#{run}"), local: value(local), report: "reverted" })
  end

  # The red flag was lowered `at` seconds into the example; the flag's own key is the landed commit.
  #
  # @return [Array<Hash>] one record per policy that heard it
  def flag_cleared(at:)
    allow(Hecks::Ports::Clock).to receive(:now).and_return(epoch + at)
    hear("RedFlagCleared", "RedFlag", key("landed-#{at}"), { flag: value("flag-1"), commit: value("landed-#{at}") })
  end

  # @return [Array<Hash>] the rows of one RedEpisode query
  def asked(query, **args) = RedEpisodeHelpers.hecks.query("Hecks::RedEpisode.#{query}", **args)

  # @return [Hash] the record of episode `run`
  def episode(run) = asked("Recent", limit: 100_000).find { |row| row[:id] == key(run) }

  # @return [Integer] the seconds into the example an instant of episode `run` holds, 0 when unset
  def seconds(run, instant)
    held = episode(run)[instant]&.value.to_i
    held.zero? ? 0 : held - epoch
  end

  # @return [Array] the episode's ending, then the seconds into the example it began and ended
  def ended(run) = [held(run, :ending), seconds(run, :began_at), seconds(run, :ended_at)]

  # @return [String, nil] the text one attribute of episode `run` holds
  def held(run, name)
    kept = episode(run)[name]
    kept.respond_to?(:value) ? kept.value : kept
  end

  # @return [Array<String>] the example's own runs among `rows`, in the order listed
  def mine(rows)
    prefix = key("")
    rows.map { |row| row[:id] }.select { |run| run.start_with?(prefix) }.map { |run| run.delete_prefix(prefix) }
  end
end

RSpec.shared_context "with red episodes in Memory" do
  include RedEpisodeHelpers

  around do |example|
    RedEpisodeHelpers.hecks
    Hecks::Runtime::AdapterLookup.standing_in(Hecks::Fuzzing::OutsideWorld) { example.run }
  end
end

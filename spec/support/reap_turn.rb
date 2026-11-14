# frozen_string_literal: true

# What a spec of the turn to reap sends and reads, over the reaping fleet: the clock the `needs`
# of `ReapTurn.Take` reads, a beat, a take by hand, and how many reaps the turn started.
module ReapTurnSteps
  REFUSAL = "no reap is running"

  def at(time) = allow(Hecks::Ports::Clock).to receive(:now).and_return(time)

  def beat(key) = launch("heartbeat.beat!", "beat=#{key}", "--wait")

  def take(run, at:, spacing: 0)
    launch("reap_turn.take!", "to=sessions", "run.value=#{run}", "spacing.value=#{spacing}", "lease.value=3600",
           "now.value=#{at}", "--wait")
  end

  def turns = @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("ReapTurn"))

  # The turn as a reap whose process was killed leaves it: taken, and never freed. The port
  # ends every reap it begins, a failing one too, so only the record can stand for a killed one.
  def killed_reap(at:)
    turn = turns.find("sessions")
    turn.state.merge!(held: { value: 1 }, taken_at: { value: at })
    turns.save(turn)
  end

  def delivered(policy) = @hecks.registry.reaction_log.count { |row| row[:policy] == policy && row[:delivered] }

  def reaps = delivered("ReapWhenTheTurnIsTaken")
end

# The clock at noon and one beat, which opens the turn and reaps: every later cause finds the
# turn open and the last reap begun at noon.
RSpec.shared_context "with a first beat at noon" do
  include ReapTurnSteps

  let(:noon) { now.to_i }

  before do
    listing("plain-1", "working")
    at(noon)
    beat("b1")
  end
end

require_relative "agents_memory_boot"

# Sends a message and reads a run's inbox on the Agents bluebook `AgentsMemoryBoot` booted, with
# its ports and the `Recipients` adapter, which reads the stand-in runs and session listing
# {#recipients} names instead of the AgentRun ledger and `claude agents`.
module AgentsMessageHelpers
  PORTS = [File.join(InMemoryDomain::ROOT, "lib/hecks/agents/agents.ports.hecksagon"),
           File.join(InMemoryDomain::ROOT, "lib/hecks/agents/adapters/recipient_check.adapter")].freeze

  # A run that is started and holds a session.
  def live_run = { status: "started", session: "5e55" }

  # Boots the Agents bluebook with the `Recipients` port bound.
  def boot_messages = AgentsMemoryBoot.call(extra: PORTS)

  # The runs the stand-in ledger holds, by key; every recipient the examples name is live.
  def recipients = { "run-a" => live_run, "run-b" => live_run, "orchestrator" => live_run }

  # The session ids the stand-in listing shows.
  def listed_sessions = []

  def send_message(key: "m1", to: "run-a", kind: "answer", body: "use the smaller version", reply: "")
    check = Hecks::Adapters::RecipientCheck.new(runs: -> { recipients }, listed: ->(id) { listed_sessions.include?(id) })
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { check }) do
      Hecks::Agents::Message.send!(message: { value: key }, recipient: { value: to }, sender: { value: "orchestrator" },
                                   kind: { value: kind }, body: { value: body }, in_reply_to: { value: reply })
    end
    Hecks::Agents::Message.find(key)
  end

  def inbox(run) = Hecks::Agents::Message.inbox(recipient: { value: run }).map { |row| row[:message].value }
end

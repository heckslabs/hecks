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
  def boot_messages = (@agents_runtime = AgentsMemoryBoot.call(extra: PORTS))

  # Registers a hand-started session through the booted Agents bluebook.
  def register_hand(run: "owner-orchestrator", session: "134d89bd-full", role: "orchestrator-owner", checkout: nil)
    words = { run: { value: run }, session: { value: session }, role: { value: role } }
    words[:checkout] = { value: checkout } if checkout
    Hecks::Agents::HandRun.register!(**words)
  end

  # The runs the stand-in ledger holds, by key; every recipient the examples name is live.
  def recipients = { "run-a" => live_run, "run-b" => live_run, "orchestrator" => live_run }

  # The session ids the stand-in listing shows.
  def listed_sessions = []

  # The hand runs the stand-in reads, by key; none unless an example names some. An example that
  # registers through `HandRun.register!` reads the booted rows by leaving this nil.
  def hand_runs = nil

  def send_message(key: "m1", to: "run-a", sender: "orchestrator", **said)
    check = Hecks::Adapters::RecipientCheck.new(registry: @agents_runtime&.registry, runs: -> { recipients },
                                                listed: ->(id) { listed_sessions.include?(id) },
                                                hand_runs: hand_runs && -> { hand_runs })
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { check }) do
      Hecks::Agents::Message.send!(**message_words(key, to, sender, said))
    end
    Hecks::Agents::Message.find(key)
  end

  def inbox(run) = Hecks::Agents::Message.inbox(recipient: { value: run }).map { |row| row[:message].value }

  def message_words(key, to, sender, said)
    { message: key, recipient: to, sender: sender, kind: said.fetch(:kind, "answer"),
      body: said.fetch(:body, "use the smaller version"), in_reply_to: said.fetch(:reply, "") }
      .transform_values { |value| { value: value } }
  end
end

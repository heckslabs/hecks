require_relative "agents_memory_boot"

# Sends a message and reads a run's inbox on the Agents bluebook `AgentsMemoryBoot` booted.
module AgentsMessageHelpers
  def send_message(key: "m1", to: "run-a", kind: "answer", body: "use the smaller version", reply: "")
    Hecks::Agents::Message.send!(message: { value: key }, recipient: { value: to }, sender: { value: "orchestrator" },
                                 kind: { value: kind }, body: { value: body }, in_reply_to: { value: reply })
  end

  def inbox(run) = Hecks::Agents::Message.inbox(recipient: { value: run }).map { |row| row[:message].value }
end

require "spec_helper"
require_relative "support/agents_message_helpers"
require_relative "support/agents_kept_store"

# A registration made by one process is seen by the recipient check of another: the Agents
# bluebook is booted twice, each boot its own registry, over the store the overlay binds.
RSpec.describe "a hand-started session's registration, across processes" do
  include AgentsMessageHelpers

  let(:root) { Dir.mktmpdir("hand-run-store") }
  let(:rows) { Hecks::Adapters::MainIntegration::KeptRows.from_registry(boot_hecks_in_memory.registry) }

  after { FileUtils.remove_entry(root) }

  def boot_process
    extra = AgentsMessageHelpers::PORTS + AgentsKeptStore.files(root, rows)
    @agents_runtime = AgentsMemoryBoot.call(extra: extra)
  end

  def listed_sessions = ["134d89bd-full"]

  def recipients = {}

  it "delivers a message in a second process to the session the first registered" do
    boot_process
    register_hand
    boot_process
    expect(send_message(to: "owner-orchestrator").status).to eq("sent")
  end
end

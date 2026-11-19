# frozen_string_literal: true

require "spec_helper"
require_relative "support/project_board_fixture"
require "hecks/pipeline_board/adapters/pipeline_tickets/project_store"

# Another project's Tickets store, found from the text of its checkout's local world and read
# read-only, without booting the project.
RSpec.describe Hecks::Adapters::PipelineBoard::ProjectStore do
  subject(:store) { described_class.new(checkout: ProjectBoardFixture.checkout(projects, works: works)) }

  let(:projects) { Dir.mktmpdir("project-boards") }
  let(:works) { [["make-a-short", "planned", 2, "growth"], ["ship-it", "done", 1, nil]] }

  after { FileUtils.rm_rf(projects) }

  def unavailable = Hecks::Adapters::PipelineBoard::Unavailable

  it "finds the database the checkout's Tickets world names, not another world's" do
    expect(store.database).to eq(File.join(projects, "tickets.db"))
  end

  it "reads each Work item with its value objects read back plain" do
    expect(store.read[:works].first).to include(work: "make-a-short", step: 2, epic: "growth", area: [{ value: "bluebook" }])
  end

  it "reads each epic" do
    expect(store.read[:epics]).to eq([{ epic: "growth", title: "Grow", outcome: "More shorts" }])
  end

  it "creates nothing beside the store it reads" do
    store.database
    expect { store.read }.not_to(change { Dir.children(projects).sort })
  end

  it "says so when no local world names a Tickets store" do
    expect { described_class.new(checkout: projects).read }.to raise_error(unavailable, /no local world/)
  end

  it "says which needed column a changed store lacks" do
    store.database
    SQLite3::Database.new(File.join(projects, "tickets.db")).execute('ALTER TABLE "work" DROP COLUMN "step"')
    expect { store.read }.to raise_error(unavailable, /no step column/)
  end
end

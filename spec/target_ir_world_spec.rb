require "tmpdir"
require "fileutils"
require "hecks"
require "hecks/rust_build"

RSpec.describe "the target IR's world key" do
  let(:root) { Dir.mktmpdir }
  let(:bluebook_dir) { File.join(root, "shop", "bluebook") }
  let(:empty) { { "default_adapter" => nil, "default_database" => false, "persistence" => [] } }

  before { FileUtils.mkdir_p(bluebook_dir) }

  after { FileUtils.remove_entry(root) }

  def write_world(text) = File.write(File.join(bluebook_dir, "shop.world"), text)

  def world_key
    ir = Hecks::RustBuild::ProjectRust::TargetIr.new(nil, "Shop", bluebook_dir)
    ir.send(:world, Hecks::Projector::Exporter)
  end

  it "is the empty default with no world file" do
    expect(world_key).to eq(empty)
  end

  it "is the empty default when the file holds another domain's world" do
    write_world(%(Hecks.world "Other" do\n  persisted_by("Heki") { dir "data" }\nend\n))
    expect(world_key).to eq(empty)
  end

  it "lists persisted_by binds with setting names only", :aggregate_failures do
    write_world(<<~WORLD)
      Hecks.world "Shop" do
        persisted_by("Postgres") do
          url "postgres://user:secret@host/db"
        end
        projected_by("Sqlite") { database "x.sqlite3" }
      end
    WORLD
    expect(world_key["persistence"]).to eq([{ "adapter" => "Postgres", "settings" => ["url"] }])
    expect(JSON.generate(world_key)).not_to include("postgres://")
  end

  it "reports a world with only a default adapter" do
    write_world(%(Hecks.world "Shop" do\n  default_adapter "Memory"\nend\n))
    expect(world_key).to eq(empty.merge("default_adapter" => "Memory"))
  end
end

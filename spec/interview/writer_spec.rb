require "spec_helper"
require "hecksagain/interview"
require "tmpdir"

RSpec.describe Hecksagain::Interview::Writer do
  # A REAL, SEALED declaration — Writer's own `verify!` loads what it
  # renders through the ordinary `Hecks.bluebook` path, and MetaValidator
  # refuses an unsealed one the same way it refuses any incomplete real
  # bluebook (confirmed live: a Declare with no Identify raises
  # `DSL::Malformed`, "an aggregate says what it is known by", before
  # `save!` ever reaches disk). `save!` is only ever meaningful once the
  # interview has reached a state the language itself calls well-formed.
  def sealed_declaration(chapter = "Loyalty")
    session = Hecksagain::Interview::Session.open(chapter)
    session.offer("Bluebook::Aggregate.Declare", bluebook_id: chapter, name: { value: "Member" })
    session.offer("Bluebook::ValueObject.Declare", aggregate_id: "#{chapter}:Member", name: { value: "Points" })
    session.offer("Bluebook::Aggregate.Attribute", id: "#{chapter}:Member", type: "#{chapter}:Member:Points",
                                                    name: { value: "points" }, list: { value: false })
    session.offer("Bluebook::Aggregate.Identify", id: "#{chapter}:Member", path: { value: "points.value" })
    session.declaration
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  it "writes a whole, immediately bootable domain directory" do
    path = described_class.save!(sealed_declaration, to: @dir)

    expect(path).to eq(File.join(@dir, "bluebook", "loyalty.bluebook"))
    expect(File).to exist(File.join(@dir, "bluebook", "loyalty.hecksagon"))
    expect(File).to exist(File.join(@dir, "bluebook", "loyalty.world"))

    runtime = Hecks.boot(@dir)
    expect(runtime.registry.bluebooks.keys).to eq(["Loyalty"])
  end

  it "binds every aggregate to Memory in the generated hecksagon" do
    described_class.save!(sealed_declaration, to: @dir)
    hecksagon = File.read(File.join(@dir, "bluebook", "loyalty.hecksagon"))

    expect(hecksagon).to include('Loyalty::Member.persisted_by("Memory")')
  end

  it "is idempotent — saving the same declaration twice does not raise" do
    described_class.save!(sealed_declaration, to: @dir)

    expect { described_class.save!(sealed_declaration, to: @dir) }.not_to raise_error
  end

  it "refuses to overwrite a file a human (or anything else) changed since the last write" do
    path = described_class.save!(sealed_declaration, to: @dir)
    File.write(path, "#{File.read(path)}\n# hand-added\n")

    expect { described_class.save!(sealed_declaration, to: @dir) }
      .to raise_error(described_class::Drifted, /changed since/)
  end

  it "verifies before writing anything — an unsealed declaration writes no FILE at all " \
     "(the empty bluebook/ dir from mkdir_p is harmless and not what this guards)" do
    session = Hecksagain::Interview::Session.open("Loyalty")
    session.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })

    expect { described_class.save!(session.declaration, to: @dir) }
      .to raise_error(Hecksagain::Bluebook::DSL::Malformed)
    expect(Dir.glob(File.join(@dir, "**/*")).select { |path| File.file?(path) }).to be_empty
  end
end

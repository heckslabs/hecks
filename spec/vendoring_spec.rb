require "tmpdir"
require_relative "support/registry_repo"

RSpec.describe Hecks::Vendoring do
  let(:scratch) { Dir.mktmpdir("hecks-vendoring-spec") }
  let(:repo) { RegistryRepo.new(File.join(scratch, "source")) }
  let(:into) { File.join(scratch, "project", "vendor", "widgets") }

  after { FileUtils.remove_entry(scratch) }

  def seed(bluebook: "first\n")
    repo.write(
      "widgets/bluebook/widgets.bluebook"        => bluebook,
      "widgets/bluebook/other.bluebook"          => "other\n",
      "widgets/bluebook/widgets.hecksagon"       => "wiring\n",
      "widgets/bluebook/hecksagon/demo.bluebook" => "nested\n",
      "widgets/spec/widget_spec.rb"              => "spec\n"
    )
    repo.commit
  end

  def pin(**overrides, &)
    described_class.pin(from: repo.path, ref: "main", subtree: "widgets/bluebook", into: into,
                        glob: "*.bluebook", **overrides, &)
  end

  it "exports only the top-level files matching the glob, keeping the subtree's own name" do
    seed

    result = pin

    expect(result.files).to eq(%w[other.bluebook widgets.bluebook])
    expect(Dir.children(File.join(into, "bluebook")).sort).to eq(%w[other.bluebook widgets.bluebook])
    expect(result.dir).to eq(File.join(into, "bluebook"))
  end

  it "records the full commit id in the marker" do
    commit = seed

    result = pin

    expect(result.commit).to eq(commit)
    expect(File.read(File.join(into, "VENDORED_COMMIT"))).to eq("#{commit}\n")
  end

  it "exports the commit, never the working tree or a later commit" do
    first = seed
    repo.write("widgets/bluebook/widgets.bluebook" => "second\n")
    repo.commit
    repo.write("widgets/bluebook/widgets.bluebook" => "uncommitted\n")

    pin(ref: first)

    expect(File.read(File.join(into, "bluebook", "widgets.bluebook"))).to eq("first\n")
  end

  it "replaces what was there, dropping files the source no longer has" do
    seed
    FileUtils.mkdir_p(File.join(into, "bluebook"))
    File.write(File.join(into, "bluebook", "stale.bluebook"), "stale\n")
    File.write(File.join(into, "bluebook.lock"), "old lock\n")

    pin

    expect(Dir.children(into).sort).to eq(%w[VENDORED_COMMIT bluebook])
  end

  it "writes the extra files a block returns beside the marker" do
    seed

    pin { |staged, commit| { "notes.txt" => "#{Dir.children(staged).size} files at #{commit[0, 7]}\n" } }

    expect(File.read(File.join(into, "notes.txt"))).to match(/\A2 files at \h{7}\n\z/)
  end

  it "leaves the existing directory alone when the block refuses" do
    seed
    pin
    repo.write("widgets/bluebook/widgets.bluebook" => "second\n")
    repo.commit

    expect { pin { raise Hecks::Vendoring::Error, "no" } }.to raise_error(Hecks::Vendoring::Error, "no")
    expect(File.read(File.join(into, "bluebook", "widgets.bluebook"))).to eq("first\n")
  end

  it "refuses a ref that names no commit" do
    seed

    expect { pin(ref: "nope") }.to raise_error(Hecks::Vendoring::Error, /no commit "nope"/)
  end

  it "refuses a subtree with no matching file, without creating the destination" do
    seed

    expect { pin(subtree: "widgets/spec", glob: "*.bluebook") }
      .to raise_error(Hecks::Vendoring::Error, %r{no \*\.bluebook files in widgets/spec})
    expect(File.exist?(into)).to be(false)
  end

  it "refuses a source that is not a directory" do
    expect { described_class.pin(from: File.join(scratch, "missing"), ref: "main", subtree: "a", into: into) }
      .to raise_error(Hecks::Vendoring::Error, /no source repository/)
  end
end

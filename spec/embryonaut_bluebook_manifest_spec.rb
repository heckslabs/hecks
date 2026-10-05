require "json"
require "tmpdir"
require_relative "support/registry_repo"

RSpec.describe Hecks::EmbryonautBluebook::Manifest, :io do
  let(:scratch) { Dir.mktmpdir("hecks-manifest-spec") }
  let(:repo) { RegistryRepo.new(File.join(scratch, "registry")) }
  let(:root) { File.join(scratch, "project") }
  let(:package_dir) { File.join(root, "vendor", "embryonaut_bluebooks", "widgets") }

  after { FileUtils.remove_entry(scratch) }

  def release(version)
    repo.write("widgets/bluebook.yml"              => "name: widgets\nversion: #{version}\nsummary: Widgets.\n",
               "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook)
    repo.commit("widgets #{version}")
    repo.tag("widgets-v#{version}")
  end

  def vendor = Hecks::EmbryonautBluebook.vendor!("widgets", from: repo.path, root: root)

  def problems
    described_class.new(root).call
    []
  rescue described_class::Mismatch => e
    e.problems
  end

  it "describes a vendored package by its lock" do
    release("1.2.0")
    result = vendor

    manifest = described_class.new(root, built_from: { "commit" => "abc", "dirty" => false }).call

    expect(manifest).to eq(
      "built_from" => { "commit" => "abc", "dirty" => false },
      "bluebooks"  => { "widgets" => { "version" => "1.2.0", "tag" => "widgets-v1.2.0", "commit" => result.commit,
                                       "digest" => result.digest, "shape" => result.shape } }
    )
  end

  it "uses the digest the vendoring wrote, from Lock.digest_of" do
    release("1.0.0")
    vendor

    digest = described_class.new(root).call.dig("bluebooks", "widgets", "digest")

    expect(digest).to eq(Hecks::EmbryonautBluebook::Lock.digest_of(File.join(package_dir, "bluebook")))
  end

  it "has no packages for a project that vendors none" do
    FileUtils.mkdir_p(root)

    expect(described_class.new(root).call).to eq("bluebooks" => {})
  end

  it "writes sorted keys with a trailing newline, the same text every time" do
    release("1.0.0")
    vendor

    text = described_class.new(root).to_json_text

    expect(text).to end_with("}\n")
    expect(JSON.parse(text).fetch("bluebooks").fetch("widgets").keys).to eq(%w[commit digest shape tag version])
    expect(described_class.new(root).to_json_text).to eq(text)
  end

  it "refuses a vendored file edited by hand" do
    release("1.0.0")
    vendor
    File.write(File.join(package_dir, "bluebook", "widgets.bluebook"), "# edited\n", mode: "a")

    expect(problems.first).to match(/\Awidgets: vendored files hash to \h{12}, but bluebook.lock says \h{12}/)
  end

  it "refuses a package with no lock" do
    FileUtils.mkdir_p(File.join(package_dir, "bluebook"))

    expect(problems).to eq(["widgets: no bluebook.lock (hecks package.vendor widgets@<version>)"])
  end

  it "refuses a lock missing a field, naming the field" do
    release("1.0.0")
    vendor
    lock = File.join(package_dir, "bluebook.lock")
    File.write(lock, File.readlines(lock).grep_v(/\Acommit:/).join)

    expect(problems).to eq(["widgets: bluebook.lock has no commit"])
  end

  it "refuses a lock whose tag does not match its version, or that names another package" do
    release("1.0.0")
    vendor
    lock = File.join(package_dir, "bluebook.lock")
    edited = File.read(lock).sub("tag: widgets-v1.0.0", "tag: widgets-v2.0.0").sub("package: widgets", "package: gadgets")
    File.write(lock, edited)

    expect(problems).to contain_exactly("widgets: bluebook.lock names package gadgets",
                                        "widgets: bluebook.lock tag widgets-v2.0.0 is not widgets-v1.0.0")
  end

  it "reports every package that disagrees, one FAIL line each" do
    release("1.0.0")
    vendor
    FileUtils.mkdir_p(File.join(root, "vendor", "embryonaut_bluebooks", "gadgets", "bluebook"))

    FileUtils.mkdir_p(File.join(root, "vendor", "embryonaut_bluebooks", "doodads", "bluebook"))

    expect { described_class.new(root).call }
      .to raise_error(described_class::Mismatch, /\AFAIL doodads: no bluebook.lock.*\nFAIL gadgets: no bluebook.lock/)
  end
end

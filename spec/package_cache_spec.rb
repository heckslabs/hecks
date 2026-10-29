require "fileutils"
require "json"
require "tmpdir"
require_relative "support/registry_repo"
require_relative "../lib/hecks/embryonaut_bluebook/package_cache"
require_relative "../lib/hecks/behaviors/dsl"

RSpec.describe Hecks::EmbryonautBluebook::PackageCache do
  let(:scratch) { Dir.mktmpdir("hecks-package-cache-spec") }
  let(:repo) { RegistryRepo.new(File.join(scratch, "registry")) }
  let(:project) { File.join(scratch, "project", "bluebook") }
  let(:project_lock) { File.join(project, "packages.lock") }

  # The cache is scratch space for each example, including the subprocess a behaviors build runs.
  around do |example|
    previous = ENV.fetch("XDG_CACHE_HOME", nil)
    ENV["XDG_CACHE_HOME"] = File.join(scratch, "cache")
    example.run
  ensure
    ENV["XDG_CACHE_HOME"] = previous
  end

  before do
    allow(Hecks::CacheDir).to receive(:path) { |name| File.join(scratch, "cache", name) }
  end

  after { FileUtils.remove_entry(scratch) }

  # Commits and tags one release of the `widgets` package, with a bluebook and an adapter.
  def release(version, adapter: "# widgets adapter\n")
    repo.write(
      "widgets/bluebook.yml"               => "name: widgets\nversion: #{version}\nsummary: Widgets.\n",
      "widgets/bluebook/widgets.bluebook"  => RegistryRepo.widgets_bluebook,
      "widgets/bluebook/widgets.hecksagon" => "Hecks.hecksagon \"Widgets\" do\nend\n",
      "widgets/bluebook/widgets.adapter"   => adapter
    )
    repo.commit("widgets #{version}")
    repo.tag("widgets-v#{version}")
  end

  def resolve(version) = described_class.resolve("widgets", version, from: repo.path, project_lock: project_lock)

  def project_files = Dir.glob(File.join(scratch, "project", "**", "*")).select { |path| File.file?(path) }

  def pinned_version = JSON.parse(File.read(project_lock)).fetch("widgets").fetch("version")

  # @return [Symbol] `:refused` when the resolution is refused as drift, `:resolved` otherwise
  def refused_move(version)
    resolve(version)
    :resolved
  rescue described_class::Drifted
    :refused
  end

  it "resolves the release's bluebook and adapter files" do
    release("1.0.0")

    expect(resolve("1.0.0").map { |path| File.basename(path) })
      .to eq(%w[widgets.adapter widgets.bluebook widgets.hecksagon])
  end

  it "keeps the resolved files in the cache, not the project" do
    release("1.0.0")

    expect(resolve("1.0.0")).to all(start_with(File.join(scratch, "cache")))
  end

  it "writes only the pin into the project" do
    release("1.0.0")
    resolve("1.0.0")

    expect(project_files).to eq([project_lock])
  end

  it "records the resolved version in the project's packages.lock" do
    release("1.0.0")
    resolve("1.0.0")

    expect(pinned_version).to eq("1.0.0")
  end

  it "resolves again from the cache after the registry is gone" do
    release("1.0.0")
    first = resolve("1.0.0")
    FileUtils.remove_entry(repo.path)

    expect(resolve("1.0.0")).to eq(first)
  end

  it "refuses a cached file that no longer matches its lock digest" do
    release("1.0.0")
    adapter = resolve("1.0.0").find { |path| path.end_with?(".adapter") }
    File.write(adapter, "# altered\n")

    expect { resolve("1.0.0") }.to raise_error(described_class::Tampered, /bluebook\.lock digest/)
  end

  it "refuses a resolution that moves a pinned package to another version" do
    release("1.0.0")
    resolve("1.0.0")
    release("1.1.0", adapter: "# changed\n")

    expect { resolve("1.1.0") }.to raise_error(described_class::Drifted, /pins 1\.0\.0/)
  end

  it "leaves the pin the project recorded unchanged when a move is refused" do
    release("1.0.0")
    resolve("1.0.0")
    release("1.1.0", adapter: "# changed\n")
    expect([refused_move("1.1.0"), pinned_version]).to eq([:refused, "1.0.0"])
  end

  describe "a behaviors file that names a package" do
    def build_suite(**package_options)
      source = File.join(project, "gadgets.behaviors")
      Hecks::Behaviors::BehaviorsBuilder.build("Gadgets", source_path: source) do
        vision "Gadgets boot widgets."
        loads "miette.bluebook", package("widgets", "1.0.0", **package_options)
      end
    end

    it "keeps a plain path in declaration order" do
      release("1.0.0")

      expect(build_suite(from: repo.path).loads.first).to eq(File.join(project, "miette.bluebook"))
    end

    it "replaces a package reference with its cached files" do
      release("1.0.0")

      expect(build_suite(from: repo.path).loads.drop(1).map { |path| File.basename(path) })
        .to eq(%w[widgets.adapter widgets.bluebook widgets.hecksagon])
    end

    it "refuses a package that names no registry" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("HECKS_REGISTRY").and_return(nil)

      expect { build_suite }.to raise_error(Hecks::Behaviors::Malformed, /names no registry/)
    end
  end
end

require "stringio"
require "tmpdir"
require_relative "support/registry_repo"

RSpec.describe Hecks::EmbryonautBluebook, ".vendor!" do
  let(:scratch) { Dir.mktmpdir("hecks-vendor-spec") }
  let(:repo) { RegistryRepo.new(File.join(scratch, "registry")) }
  let(:root) { File.join(scratch, "project") }
  let(:package_dir) { File.join(root, "vendor", "embryonaut_bluebooks", "widgets") }

  after { FileUtils.remove_entry(scratch) }

  # Commits a state of the `widgets` package and tags it as a release.
  def release(version, **bluebook)
    write_package(version, **bluebook)
    commit = repo.commit("widgets #{version}")
    repo.tag("widgets-v#{version}")
    commit
  end

  def write_package(version, **bluebook)
    repo.write(
      "widgets/bluebook.yml"                     => "name: widgets\nversion: #{version}\nsummary: Widgets.\n",
      "widgets/bluebook/widgets.bluebook"        => RegistryRepo.widgets_bluebook(**bluebook),
      "widgets/bluebook/widgets.hecksagon"       => "Hecks.hecksagon \"Widgets\" do\nend\n",
      "widgets/bluebook/hecksagon/demo.bluebook" => "raise 'never loaded'\n",
      "widgets/spec/widget_spec.rb"              => "spec\n"
    )
  end

  def vendor(**options) = described_class.vendor!("widgets", from: repo.path, root: root, **options)

  def lock = Hecks::EmbryonautBluebook::Lock.read(File.join(package_dir, "bluebook.lock"))

  # The digest the registry's own bin/bluebook_digest prints: sha256 over the
  # sha256 lines of the sorted top-level bluebook files, in the C locale.
  def shell_digest(dir)
    out, = Open3.capture2({ "LC_ALL" => "C" }, "sh", "-c", "shasum -a 256 -- *.bluebook | shasum -a 256 | cut -d' ' -f1",
                          chdir: dir)
    out.strip
  end

  describe "a release" do
    let!(:commit) { release("1.0.0") }

    it "vendors the bluebook files where load! looks for them, and only those" do
      vendor(ref: "1.0.0")

      expect(Dir.children(File.join(package_dir, "bluebook"))).to eq(["widgets.bluebook"])
      expect(File.read(File.join(package_dir, "bluebook", "widgets.bluebook"))).to eq(RegistryRepo.widgets_bluebook)
    end

    it "writes the commit marker and a lock naming the release" do
      result = vendor(ref: "1.0.0")

      expect(File.read(File.join(package_dir, "VENDORED_COMMIT"))).to eq("#{commit}\n")
      expect(lock.to_h).to include(package: "widgets", version: "1.0.0", tag: "widgets-v1.0.0", commit: commit)
      expect(lock.shape).to eq(result.shape)
      expect(result.shape.first).to match(/\AWidgets \h{6}\z/)
    end

    it "records the digest the registry's own script computes" do
      vendor(ref: "1.0.0")

      expect(lock.digest).to eq(shell_digest(File.join(package_dir, "bluebook")))
    end

    it "round-trips the lock file" do
      vendor(ref: "1.0.0")

      text = File.read(File.join(package_dir, "bluebook.lock"))

      expect(Hecks::EmbryonautBluebook::Lock.parse(text).to_s).to eq(text)
    end

    it "takes the newest release when no ref is given, ordering versions numerically" do
      release("1.9.0")
      release("1.10.0", description: "A widget, described further.")

      expect(vendor.version).to eq("1.10.0")
    end

    it "accepts the tag name as the ref" do
      expect(vendor(ref: "widgets-v1.0.0").version).to eq("1.0.0")
    end

    it "loads through load! afterwards" do
      vendor(ref: "1.0.0")
      registry = Hecks::Runtime::Registry.new(root: root)

      Hecks.with_registry(registry) do
        Hecks::Ports::Loading.bootstrap.load_library
        described_class.load!("widgets", registry: registry)
      end

      expect(registry.bluebook("Widgets")).not_to be_nil
    end

    it "refuses a release the source does not have, naming the ones it does" do
      expect { vendor(ref: "2.0.0") }
        .to raise_error(Hecks::Vendoring::Error, /no release widgets-v2\.0\.0.*releases: 1\.0\.0/)
    end

    it "refuses a tag whose commit says a different version" do
      repo.tag("widgets-v1.5.0")

      expect { vendor(ref: "1.5.0") }
        .to raise_error(Hecks::Vendoring::Error, /widgets-v1\.5\.0 points at a commit whose bluebook\.yml says version "1\.0\.0"/)
    end

    it "refuses a package name that is not a plain name" do
      expect { described_class.vendor!("../widgets", from: repo.path, root: root) }
        .to raise_error(Hecks::Vendoring::Error, /not a package name/)
    end

    it "refuses a package the source does not carry" do
      expect { described_class.vendor!("gadgets", from: repo.path, root: root) }
        .to raise_error(Hecks::Vendoring::Error, /no gadgets-v\* release tag/)
    end
  end

  describe "a bare commit" do
    it "pins that commit with the marker alone: no lock, no version checks" do
      release("1.0.0")
      repo.write("widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook(description: "Newer."))
      newer = repo.commit("unreleased")

      result = vendor(ref: newer)

      expect(result).not_to be_release
      expect(Dir.children(package_dir).sort).to eq(%w[VENDORED_COMMIT bluebook])
      expect(File.read(File.join(package_dir, "VENDORED_COMMIT"))).to eq("#{newer}\n")
    end

    it "exports the named commit when a later one exists" do
      write_package("0.0.0")
      first = repo.commit("first")
      repo.write("widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook(description: "Later."))
      repo.commit("second")

      vendor(ref: first)

      expect(File.read(File.join(package_dir, "bluebook", "widgets.bluebook"))).to eq(RegistryRepo.widgets_bluebook)
    end
  end

  describe "version policy" do
    it "refuses a release older than the vendored one, unless allowed" do
      release("1.0.0")
      release("1.1.0", description: "Reworded.")
      vendor(ref: "1.1.0")

      expect { vendor(ref: "1.0.0") }.to raise_error(Hecks::Vendoring::Error, /1\.1\.0 is vendored; 1\.0\.0 is older/)
      expect(lock.version).to eq("1.1.0")
      expect(vendor(ref: "1.0.0", allow_downgrade: true).version).to eq("1.0.0")
    end

    it "allows a patch release that leaves the storage shape alone" do
      release("1.0.0")
      release("1.0.1", description: "Reworded.")
      vendor(ref: "1.0.0")

      result = vendor(ref: "1.0.1")

      expect(result.previous_version).to eq("1.0.0")
      expect(result).not_to be_shape_changed
    end

    it "refuses a patch release that changes the storage shape, and changes nothing" do
      release("1.0.0")
      release("1.0.1", extra_attribute: true)
      vendor(ref: "1.0.0")

      expect { vendor(ref: "1.0.1") }
        .to raise_error(Hecks::Vendoring::Error, /changes the storage shape but is only a patch bump/)
      expect(lock.version).to eq("1.0.0")
    end

    it "allows a minor release that changes the storage shape and reports the change" do
      release("1.0.0")
      release("1.1.0", extra_attribute: true)
      vendor(ref: "1.0.0")

      result = vendor(ref: "1.1.0")

      expect(result).to be_shape_changed
      expect(result.previous_shape).not_to eq(result.shape)
    end

    it "measures the earlier copy from its files when it predates locks" do
      release("1.0.0")
      release("1.0.1", extra_attribute: true)
      vendor(ref: "1.0.0")
      File.delete(File.join(package_dir, "bluebook.lock"))

      result = vendor(ref: "1.0.1")

      expect(result.previous_version).to be_nil
      expect(result).to be_shape_changed
    end
  end

  describe "files that do not load" do
    it "refuse the pin and leave what was vendored untouched" do
      release("1.0.0")
      vendor(ref: "1.0.0")
      repo.write("widgets/bluebook.yml"              => "name: widgets\nversion: 1.1.0\n",
                 "widgets/bluebook/widgets.bluebook" => "raise 'broken'\n")
      repo.commit("broken")
      repo.tag("widgets-v1.1.0")

      expect { vendor(ref: "1.1.0") }.to raise_error(Hecks::Vendoring::Error, /do not load: RuntimeError: broken/)
      expect(lock.version).to eq("1.0.0")
    end
  end

  describe "the loader's own refusal" do
    it "points at hecks vendor when nothing is vendored" do
      registry = Hecks::Runtime::Registry.new(root: root)

      expect { described_class.load!("widgets", registry: registry) }
        .to raise_error(Hecks::Runtime::WiringError, /hecks vendor widgets/)
    end
  end

  describe Hecks::EmbryonautBluebook::VendorCli do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    def run(*argv, env: {})
      described_class.run(argv, env: env, out: out, err: err, root: root)
    end

    before { release("1.0.0") }

    it "vendors package@version from --from and reports the shape" do
      status = run("widgets@1.0.0", "--from", repo.path)

      expect(status).to eq(0)
      expect(out.string).to include("Vendored embryonaut_bluebooks/widgets 1.0.0 (widgets-v1.0.0,")
      expect(out.string).to match(/Shape: Widgets \h{6} \(no earlier vendored copy/)
      expect(File).to exist(File.join(package_dir, "bluebook.lock"))
    end

    it "takes the source from EMBRYONAUT_BLUEBOOKS_SRC and the newest release without a version" do
      expect(run("widgets", env: { "EMBRYONAUT_BLUEBOOKS_SRC" => repo.path })).to eq(0)
      expect(lock.version).to eq("1.0.0")
    end

    it "reports an unchanged shape on a second run" do
      run("widgets@1.0.0", "--from", repo.path)
      run("widgets@1.0.0", "--from", repo.path)

      expect(out.string).to include("Shape unchanged: Widgets")
    end

    it "prints the refusal and exits 1" do
      expect(run("widgets@9.9.9", "--from", repo.path)).to eq(1)
      expect(err.string).to include("no release widgets-v9.9.9")
    end

    it "prints usage and exits 2 without a source or a package" do
      expect(run("widgets")).to eq(2)
      expect(run("--from", repo.path)).to eq(2)
      expect(err.string).to include("usage: vendor_bluebook")
    end
  end
end

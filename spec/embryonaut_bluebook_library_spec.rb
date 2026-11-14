require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"

# A package that ships the Ruby its adapters run in a `lib/` directory beside `bluebook/`: vendoring
# copies it at any depth, the lock's digest covers it, and a package with none is as it was.
module LibraryPackage
  BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Widgets" do
      vision "A package with Ruby of its own."

      aggregate "Widget" do
        description "One widget."
        attribute :name, Name
        identified_by :name

        value_object "Name" do
          attribute :value, String, matches: :present
        end
      end
    end
  BLUEBOOK

  # A registry repository holding the `widgets` package, with or without a library.
  def registry(files)
    root = File.join(Dir.mktmpdir("hecks-library-registry"), "registry")
    { "widgets/bluebook/widgets.bluebook" => BLUEBOOK }.merge(files).each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), text)
    end
    commit_all(root)
    root
  end

  def commit_all(root)
    run(root, "init", "-q", "-b", "main")
    run(root, "add", ".")
    run(root, "-c", "user.name=Spec", "-c", "user.email=spec@example.invalid", "commit", "-q", "-m", "widgets")
  end

  def run(root, *words)
    out, status = Open3.capture2e("git", "-C", root, *words)
    raise "git #{words.join(" ")} failed: #{out}" unless status.success?
  end

  # Vendors `widgets` from a registry into a fresh project and answers where the package landed.
  def vendored(files)
    project = Dir.mktmpdir("hecks-library-project")
    Hecks::EmbryonautBluebook.vendor!("widgets", from: registry(files), root: project, ref: "main")
    File.join(project, "vendor", "embryonaut_bluebooks", "widgets")
  end

  def digest(package) = Hecks::EmbryonautBluebook::Lock.digest_of(File.join(package, "bluebook"))
end

RSpec.describe "a package that ships a library" do
  include LibraryPackage

  let(:library) { { "widgets/lib/adapters/builder.rb" => "# builds\n", "widgets/lib/adapters/builder/step.rb" => "# a step\n" } }

  it "vendors the library beside the bluebook, at every depth" do
    package = vendored(library)
    found = Dir.glob("lib/**/*.rb", base: package).sort
    expect(found).to eq(%w[lib/adapters/builder.rb lib/adapters/builder/step.rb])
  end

  it "vendors only the Ruby of the library" do
    package = vendored(library.merge("widgets/lib/notes.txt" => "not shipped"))
    expect(Dir.glob("lib/**/*", base: package).select { |path| File.file?(File.join(package, path)) })
      .to all(end_with(".rb"))
  end

  it "covers the library in the digest, so an edit to it is seen" do
    package = vendored(library)
    before = digest(package)
    File.write(File.join(package, "lib/adapters/builder/step.rb"), "# edited by hand\n")
    expect(digest(package)).not_to eq(before)
  end

  it "digests a package with no library as it did before one could be carried" do
    package = vendored({})
    plain = Digest::SHA256.hexdigest("#{Digest::SHA256.hexdigest(LibraryPackage::BLUEBOOK)}  widgets.bluebook\n")
    expect(digest(package)).to eq(plain)
  end

  it "leaves no library behind when the package has none" do
    expect(File).not_to exist(File.join(vendored({}), "lib"))
  end

  it "removes a library the package no longer ships when it is vendored again", :aggregate_failures do
    project = Dir.mktmpdir("hecks-library-revendor")
    Hecks::EmbryonautBluebook.vendor!("widgets", from: registry(library), root: project, ref: "main")
    Hecks::EmbryonautBluebook.vendor!("widgets", from: registry({}), root: project, ref: "main")
    expect(File).not_to exist(File.join(project, "vendor/embryonaut_bluebooks/widgets/lib"))
  end
end

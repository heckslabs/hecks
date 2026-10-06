require "tmpdir"
require_relative "support/registry_repo"

RSpec.describe Hecks::EmbryonautBluebook::Registry, :io do
  let(:scratch)  { Dir.mktmpdir("hecks-registry-spec") }
  let(:repo)     { RegistryRepo.new(File.join(scratch, "registry")) }
  let(:registry) { described_class.new(repo.path) }

  before do
    repo.git("config", "user.name", "Spec")
    repo.git("config", "user.email", "spec@example.com")
  end

  after { FileUtils.remove_entry(scratch) }

  # Writes a package's manifest, changelog and bluebook, then commits.
  def publish(version, description: "A widget.", changelog: nil, package: "widgets")
    entry = changelog || "## #{version}\n\nWhat changed in #{version}.\n\n"
    repo.write("#{package}/bluebook.yml"                 => "name: #{package}\nversion: #{version}\nsummary: Widgets.\n",
               "#{package}/CHANGELOG.md"                 => "# #{package} changelog\n\n#{entry}",
               "#{package}/bluebook/#{package}.bluebook" => RegistryRepo.widgets_bluebook(description: description))
    repo.commit("#{package} #{version}")
  end

  def released(version, **)
    publish(version, **)
    repo.tag("widgets-v#{version}")
  end

  describe "#check" do
    it "notes a package with no release yet" do
      publish("1.0.0")

      expect(registry.check.to_s).to eq("note widgets: no release tag yet (1.0.0 unreleased)\nversions ok")
    end

    it "passes a package whose files are those of its latest release" do
      released("1.0.0")

      expect(registry.check).to be_ok
      expect(registry.check.to_s).to eq("versions ok")
    end

    it "fails changed files under the same version" do
      released("1.0.0")
      publish("1.0.0", description: "Reworded.")

      report = registry.check

      expect(report.failures).to eq(["widgets: bluebook files changed since widgets-v1.0.0 but " \
                                     "bluebook.yml is still 1.0.0; bump it"])
    end

    it "fails changed files under a newer version with no changelog entry" do
      released("1.0.0")
      publish("1.1.0", description: "Reworded.", changelog: "## 1.0.0\n\nFirst.\n")

      expect(registry.check.failures).to eq(["widgets: CHANGELOG.md has no '## 1.1.0' entry"])
    end

    it "passes changed files under a newer version with a changelog entry" do
      released("1.0.0")
      publish("1.1.0", description: "Reworded.")

      expect(registry.check).to be_ok
    end

    it "compares versions as numbers, not as text" do
      released("1.9.0")
      publish("1.10.0", description: "Reworded.")

      expect(registry.check).to be_ok
    end

    it "does not fail a changelog when the files did not change" do
      released("1.0.0")
      publish("1.0.1", changelog: "")

      expect(registry.check).to be_ok
    end

    it "fails a version that is not X.Y.Z, and a name that is not the directory" do
      publish("1.0")
      repo.write("gadgets/bluebook.yml" => "name: other\nversion: 1.0.0\n", "gadgets/bluebook/gadgets.bluebook" => "#\n")
      repo.commit("gadgets")

      expect(registry.check.failures).to eq(["gadgets: bluebook.yml name does not match the directory",
                                             "widgets: version '1.0' is not X.Y.Z"])
    end

    it "fails a release tag on a commit whose bluebook.yml says another version" do
      publish("1.0.0")
      repo.tag("widgets-v2.0.0")

      expect(registry.check.failures).to include("widgets: widgets-v2.0.0 points at a commit whose " \
                                                 "bluebook.yml says '1.0.0'")
    end

    it "keeps packages in order, notes beside faults" do
      released("1.0.0")
      publish("1.0.0", package: "gadgets")
      publish("1.0.0", description: "Reworded.")

      expect(registry.check.to_s.lines.map { |line| line.split(":").first }).to eq(%w[note\ gadgets FAIL\ widgets])
    end

    it "refuses a directory that is not a git repository" do
      FileUtils.mkdir_p(File.join(scratch, "plain"))

      expect { described_class.new(File.join(scratch, "plain")) }.to raise_error(Hecks::Vendoring::Error, /not a git repository/)
    end
  end

  describe "#release" do
    it "tags the version, with the changelog section as the tag message, and reports the push command" do
      publish("1.0.0", changelog: "## 1.0.0\n\nFirst line.\n\nSecond line.\n\n## 0.9.0\n\nOlder.\n")

      tagged = registry.release("widgets")

      expect(tagged.tag).to eq("widgets-v1.0.0")
      expect(tagged.to_s).to eq("Tagged widgets-v1.0.0 at #{repo.git("rev-parse", "--short", "HEAD").strip}. " \
                                "Publish it with:\n  git push origin widgets-v1.0.0")
      expect(repo.git("cat-file", "-t", "widgets-v1.0.0").strip).to eq("tag")
      expect(repo.git("tag", "-l", "--format=%(contents)", "widgets-v1.0.0").strip)
        .to eq("widgets 1.0.0\n\nFirst line.\n\nSecond line.")
    end

    it "never pushes: a repository with no remote tags without complaint" do
      publish("1.0.0")

      expect(registry.release("widgets").tag).to eq("widgets-v1.0.0")
      expect(repo.git("remote")).to eq("")
    end

    it "refuses a tag that exists" do
      released("1.0.0")

      expect { registry.release("widgets") }.to raise_error(Hecks::Vendoring::Error, "widgets-v1.0.0 already exists")
    end

    it "refuses a version that is not newer than the latest release" do
      released("1.1.0")
      publish("1.0.5", description: "Older.")

      expect { registry.release("widgets") }
        .to raise_error(Hecks::Vendoring::Error, "1.0.5 is not newer than the latest release 1.1.0")
    end

    it "refuses a version with no changelog entry" do
      publish("1.0.0", changelog: "## 0.1.0\n\nEarlier.\n")

      expect { registry.release("widgets") }
        .to raise_error(Hecks::Vendoring::Error, "widgets/CHANGELOG.md has no '## 1.0.0' entry")
    end

    it "refuses uncommitted changes in the package" do
      publish("1.0.0")
      File.write(File.join(repo.path, "widgets/bluebook/widgets.bluebook"), "# edit\n", mode: "a")

      expect { registry.release("widgets") }
        .to raise_error(Hecks::Vendoring::Error, "widgets has uncommitted changes; commit them first")
    end

    it "refuses bluebook files identical to the latest release" do
      released("1.0.0")
      publish("1.0.1")

      expect { registry.release("widgets") }
        .to raise_error(Hecks::Vendoring::Error, "the bluebook files are identical to widgets-v1.0.0; nothing to release")
    end

    it "refuses a package the registry does not have, a bad version and a bad name" do
      publish("1.0")

      expect { registry.release("gadgets") }.to raise_error(Hecks::Vendoring::Error, "no gadgets/bluebook.yml")
      expect { registry.release("widgets") }
        .to raise_error(Hecks::Vendoring::Error, "widgets/bluebook.yml: version '1.0' is not X.Y.Z")
      expect { registry.release("../widgets") }.to raise_error(Hecks::Vendoring::Error, /is not a package name/)
    end
  end
end

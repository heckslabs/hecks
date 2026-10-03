require "spec_helper"
require "json"
require "tmpdir"
require "hecks/tools"

# ADR 0080, section 7: the Site row of the command table. The Site chapter is attached to the Hecks
# domain, so the row is `hecks site project_site`. This spec checks that the command is declared in
# the Site chapter, that its verb answers `--help` through the launcher, and then runs it against
# the sample project in spec/fixtures/site/studio: a projection written to a temporary directory,
# a `--check` that finds the file absent, then current, and a project that declares no route table.
RSpec.describe "the Site row of the ADR command table" do
  PROJECT = File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio")

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @bluebook = @hecks.registry.bluebook("Site")
  end

  after do
    Hecks::Adapters::Codebase::Tree.root = nil
  end

  def launch(argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, argv: ["site", *argv], program: "hecks")
  end

  def answer(argv)
    out, status = launch(argv)
    [JSON.parse(out), status]
  end

  it "answers (new) as SiteProjection.ProjectSite, `hecks site project_site`" do
    aggregate = @bluebook.aggregate("SiteProjection")

    expect(aggregate.commands.map(&:hecks_name)).to include("ProjectSite", "Complete", "Fault")

    out, status = launch(["project_site", "--help"])

    expect(status).to eq(0)
    expect(out).to start_with("project_site")
  end

  it "declares the Route row with the closed sets in one place" do
    route = @bluebook.aggregate("Route")

    expect(route.value_objects.map(&:hecks_name)).to include("Kind", "Render", "Auth", "CacheClass", "Origin", "Preview")
    expect(route.value_objects.find { |object| object.hecks_name == "Auth" }.members).to eq(
      [{ value: "public" }, { value: "admin" }, { value: "signed" }]
    )
  end

  it "keeps the SiteToolchain port on SiteProjection" do
    port = @bluebook.aggregate("SiteProjection").ports.find { |candidate| candidate.name == "SiteToolchain" }

    expect(port).not_to be_nil
    expect(port.operations.map(&:hecks_name)).to eq(["Project"])
  end

  it "writes routes.ts for the sample project, records it projected, and exits 0 under --wait" do
    Dir.mktmpdir("site_project") do |dir|
      json, status = answer(["project_site", PROJECT, "out=#{dir}", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
      expect(json.fetch("events")).to eq(%w[SiteProjectionRequested SiteAnswered SiteProjected])
      expect(File.read(File.join(dir, "routes.ts"))).to eq(File.read(File.join(PROJECT, "../routes.ts")))
    end
  end

  it "under --check writes nothing, records the stale file as faulted, and exits 1 under --wait" do
    Dir.mktmpdir("site_project") do |dir|
      json, status = answer(["project_site", PROJECT, "out=#{dir}", "--check", "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("faulted")
      expect(json.dig("state", "refusal", "value")).to include("out of date", "routes.ts", "run hecks project_site")
      expect(Dir.children(dir)).to be_empty
    end
  end

  it "under --check records a current file as projected" do
    Dir.mktmpdir("site_project") do |dir|
      answer(["project_site", PROJECT, "out=#{dir}", "--wait"])
      json, status = answer(["project_site", PROJECT, "out=#{dir}", "--check", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
    end
  end

  it "records a project with no route table as faulted, with the reason" do
    Dir.mktmpdir("site_project") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bluebook"))
      json, status = answer(["project_site", dir, "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("faulted")
      expect(json.dig("state", "refusal", "value")).to include("no chapter declares a value_object \"Route\"")
    end
  end

  it "refuses outside a hecks checkout, where the generator is not" do
    Dir.mktmpdir("not_a_checkout") do |dir|
      Dir.mkdir(File.join(dir, "lib"))
      Hecks::Adapters::Codebase::Tree.root = dir

      json, status = answer(["project_site", PROJECT, "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "refusal", "value")).to include("needs a hecks checkout")
    end
  end
end

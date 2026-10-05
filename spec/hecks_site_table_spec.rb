require "spec_helper"
require "json"
require "tmpdir"
require "hecks/tools"

# ADR 0080, section 7: the Site row of the command table. The Site chapter is attached to the
# Hecks domain, so the row is `hecks site site_projection.project_site`. This spec checks that the
# command is declared in the Site chapter, that its verb answers `--help` through the launcher,
# and then runs it against the sample project in spec/fixtures/site/studio: a projection written
# to a temporary directory, a `--check` that finds the file absent, then current, and a project
# that declares no route table.
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

  it "answers (new) as SiteProjection.ProjectSite, `hecks site site_projection.project_site`" do
    aggregate = @bluebook.aggregate("SiteProjection")

    expect(aggregate.commands.map(&:hecks_name)).to include("ProjectSite", "Complete", "Fault")

    out, status = launch(["site_projection.project_site", "--help"])

    expect(status).to eq(0)
    expect(out).to start_with("site_projection.project_site")
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
    expect(port.operations.map(&:hecks_name)).to eq(%w[Project Compare])
  end

  it "writes routes.ts for the sample project, records it projected, and exits 0 under --wait" do
    Dir.mktmpdir("site_project") do |dir|
      json, status = answer(["site_projection.project_site", PROJECT, "out=#{dir}", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
      expect(json.fetch("events")).to eq(%w[SiteProjectionRequested SiteAnswered SiteProjected])
      expect(File.read(File.join(dir, "routes.ts"))).to eq(File.read(File.join(PROJECT, "../routes.ts")))
    end
  end

  it "under --check writes nothing, records the stale file as faulted, and exits 1 under --wait" do
    Dir.mktmpdir("site_project") do |dir|
      json, status = answer(["site_projection.project_site", PROJECT, "out=#{dir}", "--check", "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("faulted")
      expect(json.dig("state", "refusal", "value")).to include(
        "out of date", "routes.ts", "run hecks site site_projection.project_site"
      )
      expect(Dir.children(dir)).to be_empty
    end
  end

  it "under --check records a current file as projected" do
    Dir.mktmpdir("site_project") do |dir|
      answer(["site_projection.project_site", PROJECT, "out=#{dir}", "--wait"])
      json, status = answer(["site_projection.project_site", PROJECT, "out=#{dir}", "--check", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
    end
  end

  it "records a project with no route table as faulted, with the reason" do
    Dir.mktmpdir("site_project") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bluebook"))
      json, status = answer(["site_projection.project_site", dir, "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("faulted")
      expect(json.dig("state", "refusal", "value")).to include("no chapter declares a value_object \"Route\"")
    end
  end

  it "runs outside a hecks checkout, since the tool ships in the gem and reads only the project" do
    Dir.mktmpdir("not_a_checkout") do |dir|
      Dir.mkdir(File.join(dir, "lib"))
      Hecks::Adapters::Codebase::Tree.root = dir

      Dir.mktmpdir("site_out") do |out|
        json, status = answer(["site_projection.project_site", PROJECT, "out=#{out}", "--wait"])

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("projected")
      end
    end
  end

  it "takes a template anywhere and an extension, and writes routes.mts beside an in-place template" do
    Dir.mktmpdir("site_beside") do |dir|
      FileUtils.cp(File.join(PROJECT, "deploy/template.yaml"), File.join(dir, "infra.yaml"))
      json, status = answer(["site_projection.project_site", PROJECT, "out=#{dir}/web", "template=#{dir}/infra.yaml",
                             "extension=mts", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
      expect(File.read(File.join(dir, "web/routes.mts"))).to eq(File.read(File.join(PROJECT, "../routes.ts")))
      expect(File.read(File.join(dir, "infra.yaml"))).to eq(File.read(File.join(PROJECT, "../template.yaml")))
    end
  end

  it "reads a project, an out and a template relative to where the command runs" do
    Dir.mktmpdir("site_relative") do |dir|
      FileUtils.cp_r(PROJECT, File.join(dir, "client"))
      FileUtils.rm_rf(File.join(dir, "client/generated"))
      FileUtils.mkdir_p(File.join(dir, "infra"))
      FileUtils.cp(File.join(PROJECT, "deploy/template.yaml"), File.join(dir, "infra/stack.yaml"))

      Dir.chdir(dir) do
        _, status = answer(["site_projection.project_site", "client", "out=client/web", "template=infra/stack.yaml", "--wait"])

        expect(status).to eq(0)
      end

      expect(File.read(File.join(dir, "client/web/routes.ts"))).to eq(File.read(File.join(PROJECT, "../routes.ts")))
      expect(File.read(File.join(dir, "infra/stack.yaml"))).to eq(File.read(File.join(PROJECT, "../template.yaml")))
    end
  end

  it "refuses an extension outside the set, naming the set" do
    out, status = launch(["site_projection.project_site", PROJECT, "extension=cjs", "--wait"])

    expect(status).to eq(1)
    expect(out).to include('Extension admits "ts", "mts"')
  end

  describe "site_projection.check_live" do
    require_relative "support/live_distribution"

    let(:edge) do
      site = Hecks::Projections::Site
      registry = Hecks::Tools::SiteRoutes.registry_for(PROJECT)
      chapter = site::Table.chapter(registry)
      site::Edge.read(chapter, table:      site::Table.read(chapter, registry: registry),
                               vocabulary: site::Table.vocabulary(registry))
    end
    let(:refs) { LiveDistribution.refs_for(edge) }
    let(:words) { refs.map { |name, id| "#{name}=#{id}" }.join(",") }

    def check(config, *flags)
      Dir.mktmpdir("site_live") do |dir|
        file = File.join(dir, "live.json")
        File.write(file, JSON.generate(config))
        return launch(["site_projection.check_live", PROJECT, "live=#{file}", "refs=#{words}", *flags])
      end
    end

    it "answers --help" do
      out, status = launch(["site_projection.check_live", "--help"])

      expect(status).to eq(0)
      expect(out).to start_with("site_projection.check_live")
    end

    it "prints the report alone for a live distribution that matches and exits 0, without --wait" do
      out, status = check(LiveDistribution.for(edge, refs: refs))

      expect(status).to eq(0)
      expect(out).to end_with("the live distribution matches the project")
      expect { JSON.parse(out) }.to raise_error(JSON::ParserError)
    end

    it "exits 1 printing each difference as the report" do
      config = LiveDistribution.for(edge, refs: refs)
      config.dig("DistributionConfig", "CacheBehaviors", "Items").first["TargetOriginId"] = "SomewhereElse"

      out, status, reason = check(config)

      expect(status).to eq(1)
      expect(out).to include("differs in origin")
      expect(reason).to be_nil
    end

    it "takes the behaviours a change adds as expected" do
      config = LiveDistribution.for(edge, refs: refs)
      config.dig("DistributionConfig", "CacheBehaviors", "Items").reject! { |entry| entry["PathPattern"] == "/pay/*" }

      out, status = check(config)
      expect(status).to eq(1)
      expect(out).to include("only in the project: /pay/*")

      out, status = check(config, "expect_new=/pay/*")
      expect(status).to eq(0)
      expect(out).to include("expected additions")
    end

    it "takes template= for a project whose Edge row names none, without reading the file" do
      Dir.mktmpdir("site_template") do |dir|
        FileUtils.cp_r(Dir.children(PROJECT).map { |name| File.join(PROJECT, name) }, dir)
        chapter = Dir.glob(File.join(dir, "bluebook", "*.bluebook")).find { |file| File.read(file).match?(/template:/) }
        File.write(chapter, File.read(chapter).gsub(/template: "[^"]*",\s*/, ""))
        file = File.join(dir, "live.json")
        File.write(file, JSON.generate(LiveDistribution.for(edge, refs: refs)))
        args = ["site_projection.check_live", dir, "live=#{file}", "refs=#{words}"]

        refused, refused_status = launch(args)
        out, status = launch([*args, "template=#{dir}/absent.yaml"])

        expect(refused_status).to eq(1)
        expect(refused).to include("template")
        expect(status).to eq(0)
        expect(out).to end_with("the live distribution matches the project")
      end
    end

    it "exits 1 when neither or both of a saved configuration and a distribution are named" do
      out, status = launch(["site_projection.check_live", PROJECT])
      expect(status).to eq(1)
      expect(out).to include("exactly one of a saved configuration and a distribution")

      _out, status = launch(["site_projection.check_live", PROJECT, "live=x.json", "distribution=E123"])
      expect(status).to eq(1)
    end

    it "fetches the configuration with the one read-only aws call when given a distribution" do
      config = JSON.generate(LiveDistribution.for(edge, refs: refs))
      result = Hecks::Adapters::Shell::Result.new(config, "", instance_double(Process::Status, success?: true))
      shell = instance_double(Hecks::Adapters::Shell)
      allow(Hecks::Adapters::Shell).to receive(:new).and_return(shell)
      allow(shell).to receive(:capture)
        .with("aws", "cloudfront", "get-distribution-config", "--id", "E36ACSIVZJAKNV").and_return(result)

      _out, status = launch(["site_projection.check_live", PROJECT, "distribution=E36ACSIVZJAKNV", "refs=#{words}"])

      expect(status).to eq(0)
    end

    it "exits 1 with the reason when aws fails or the saved file is missing" do
      failed = Hecks::Adapters::Shell::Result.new("", "AccessDenied", instance_double(Process::Status, success?: false))
      shell = instance_double(Hecks::Adapters::Shell, capture: failed)
      allow(Hecks::Adapters::Shell).to receive(:new).and_return(shell)

      reason, status = launch(["site_projection.check_live", PROJECT, "distribution=E1"])
      expect(status).to eq(1)
      expect(reason).to include("get-distribution-config failed: AccessDenied")

      reason, status = launch(["site_projection.check_live", PROJECT, "live=/nonexistent/live.json"])
      expect(status).to eq(1)
      expect(reason).to include("cannot read the live configuration")
    end

    it "exits 1 for a project with no edge" do
      Dir.mktmpdir("site_noedge") do |dir|
        FileUtils.mkdir_p(File.join(dir, "bluebook"))
        reason, status = launch(["site_projection.check_live", dir, "live=#{dir}/x.json"])

        expect(status).to eq(1)
        expect(reason).to include("no chapter declares a value_object")
      end
    end
  end
end

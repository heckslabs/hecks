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

  around do |example|
    Dir.mktmpdir("site_project") do |dir|
      @dir = dir
      example.run
    end
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

  # Projects the sample project into `dir` under --wait, with any extra flags.
  def project_to(dir, *flags) = answer(["site_projection.project_site", PROJECT, "out=#{dir}", *flags, "--wait"])

  # The committed output the projection of the sample project must equal.
  def golden(name) = File.read(File.join(PROJECT, "..", name))

  # Projects with the template in `dir` and the routes in `dir/web`, as an .mts module.
  def project_beside(dir)
    FileUtils.cp(File.join(PROJECT, "deploy/template.yaml"), File.join(dir, "infra.yaml"))
    answer(["site_projection.project_site", PROJECT, "out=#{dir}/web", "template=#{dir}/infra.yaml",
            "extension=mts", "--wait"])
  end

  # Copies the project to `dir/client` and runs the command from `dir` with paths relative to it.
  def project_relative(dir)
    FileUtils.cp_r(PROJECT, File.join(dir, "client"))
    FileUtils.rm_rf(File.join(dir, "client/generated"))
    FileUtils.mkdir_p(File.join(dir, "infra"))
    FileUtils.cp(File.join(PROJECT, "deploy/template.yaml"), File.join(dir, "infra/stack.yaml"))
    argv = ["site_projection.project_site", "client", "out=client/web", "template=infra/stack.yaml", "--wait"]
    Dir.chdir(dir) { answer(argv).last }
  end

  it "answers (new) as SiteProjection.ProjectSite, `hecks site site_projection.project_site`", :aggregate_failures do
    aggregate = @bluebook.aggregate("SiteProjection")

    expect(aggregate.commands.map(&:hecks_name)).to include("ProjectSite", "Complete", "Fault")

    out, status = launch(["site_projection.project_site", "--help"])

    expect(status).to eq(0)
    expect(out).to start_with("site_projection.project_site")
  end

  it "declares the Route row with the closed sets in one place", :aggregate_failures do
    route = @bluebook.aggregate("Route")

    expect(route.value_objects.map(&:hecks_name)).to include("Kind", "Render", "Auth", "CacheClass", "Origin", "Preview")
    expect(route.value_objects.find { |object| object.hecks_name == "Auth" }.members).to eq(
      [{ value: "public" }, { value: "admin" }, { value: "signed" }]
    )
  end

  it "keeps the SiteToolchain port on SiteProjection", :aggregate_failures do
    port = @bluebook.aggregate("SiteProjection").ports.find { |candidate| candidate.name == "SiteToolchain" }

    expect(port).not_to be_nil
    expect(port.operations.map(&:hecks_name)).to eq(%w[Project Compare])
  end

  it "writes routes.ts for the sample project, records it projected, and exits 0 under --wait", :aggregate_failures do
    json, status = project_to(@dir)

    expect(status).to eq(0)
    expect(json.dig("state", "status")).to eq("projected")
    expect(json.fetch("events")).to eq(%w[SiteProjectionRequested SiteAnswered SiteProjected])
    expect(File.read(File.join(@dir, "routes.ts"))).to eq(golden("routes.ts"))
  end

  it "under --check writes nothing, and exits 1 under --wait", :aggregate_failures do
    _, status = project_to(@dir, "--check")

    expect(status).to eq(1)
    expect(Dir.children(@dir)).to be_empty
  end

  it "under --check records the stale file as faulted, naming it and the command that writes it", :aggregate_failures do
    json, = project_to(@dir, "--check")

    expect(json.dig("state", "status")).to eq("faulted")
    expect(json.dig("state", "refusal", "value")).to include(
      "out of date", "routes.ts", "run hecks site site_projection.project_site"
    )
  end

  it "under --check records a current file as projected", :aggregate_failures do
    project_to(@dir)
    json, status = project_to(@dir, "--check")

    expect(status).to eq(0)
    expect(json.dig("state", "status")).to eq("projected")
  end

  it "records a project with no route table as faulted, with the reason", :aggregate_failures do
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    json, status = answer(["site_projection.project_site", @dir, "--wait"])

    expect(status).to eq(1)
    expect(json.dig("state", "status")).to eq("faulted")
    expect(json.dig("state", "refusal", "value")).to include("no chapter declares a value_object \"Route\"")
  end

  it "runs outside a hecks checkout, since the tool ships in the gem and reads only the project", :aggregate_failures do
    Dir.mkdir(File.join(@dir, "lib"))
    Hecks::Adapters::Codebase::Tree.root = @dir
    json, status = Dir.mktmpdir("site_out") { |out| project_to(out) }

    expect(status).to eq(0)
    expect(json.dig("state", "status")).to eq("projected")
  end

  it "takes a template anywhere and an extension, and projects", :aggregate_failures do
    json, status = project_beside(@dir)

    expect(status).to eq(0)
    expect(json.dig("state", "status")).to eq("projected")
  end

  it "writes routes.mts beside an in-place template", :aggregate_failures do
    project_beside(@dir)

    expect(File.read(File.join(@dir, "web/routes.mts"))).to eq(golden("routes.ts"))
    expect(File.read(File.join(@dir, "infra.yaml"))).to eq(golden("template.yaml"))
  end

  it "reads a project, an out and a template relative to where the command runs", :aggregate_failures do
    status = project_relative(@dir)

    expect(status).to eq(0)
    expect(File.read(File.join(@dir, "client/web/routes.ts"))).to eq(golden("routes.ts"))
    expect(File.read(File.join(@dir, "infra/stack.yaml"))).to eq(golden("template.yaml"))
  end

  it "refuses an extension outside the set, naming the set", :aggregate_failures do
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
    let(:config) { LiveDistribution.for(edge, refs: refs) }

    def check(config, *flags)
      Dir.mktmpdir("site_live") do |dir|
        file = File.join(dir, "live.json")
        File.write(file, JSON.generate(config))
        return launch(["site_projection.check_live", PROJECT, "live=#{file}", "refs=#{words}", *flags])
      end
    end

    def cache_items = config.dig("DistributionConfig", "CacheBehaviors", "Items")

    def drop_pay_behaviour = cache_items.reject! { |entry| entry["PathPattern"] == "/pay/*" }

    # Copies the project into `dir` with its Edge row naming no template.
    def copy_project_naming_no_template(dir)
      FileUtils.cp_r(Dir.children(PROJECT).map { |name| File.join(PROJECT, name) }, dir)
      chapter = Dir.glob(File.join(dir, "bluebook", "*.bluebook")).find { |file| File.read(file).match?(/template:/) }
      File.write(chapter, File.read(chapter).gsub(/template: "[^"]*",\s*/, ""))
    end

    # The check_live arguments for such a copy, a saved live configuration included.
    def args_for_project_naming_no_template(dir)
      copy_project_naming_no_template(dir)
      file = File.join(dir, "live.json")
      File.write(file, JSON.generate(config))
      ["site_projection.check_live", dir, "live=#{file}", "refs=#{words}"]
    end

    def aws_result(out, err, success)
      Hecks::Adapters::Shell::Result.new(out, err, instance_double(Process::Status, success?: success))
    end

    def stubbed_shell(**canned)
      instance_double(Hecks::Adapters::Shell, **canned)
        .tap { |shell| allow(Hecks::Adapters::Shell).to receive(:new).and_return(shell) }
    end

    it "answers --help", :aggregate_failures do
      out, status = launch(["site_projection.check_live", "--help"])

      expect(status).to eq(0)
      expect(out).to start_with("site_projection.check_live")
    end

    it "prints the report alone for a live distribution that matches and exits 0, without --wait", :aggregate_failures do
      out, status = check(config)

      expect(status).to eq(0)
      expect(out).to end_with("the live distribution matches the project")
      expect { JSON.parse(out) }.to raise_error(JSON::ParserError)
    end

    it "exits 1 printing each difference as the report", :aggregate_failures do
      cache_items.first["TargetOriginId"] = "SomewhereElse"
      out, status, reason = check(config)

      expect(status).to eq(1)
      expect(out).to include("differs in origin")
      expect(reason).to be_nil
    end

    it "reports a behaviour a change adds as only in the project", :aggregate_failures do
      drop_pay_behaviour
      out, status = check(config)

      expect(status).to eq(1)
      expect(out).to include("only in the project: /pay/*")
    end

    it "takes the behaviours a change adds as expected", :aggregate_failures do
      drop_pay_behaviour
      out, status = check(config, "expect_new=/pay/*")

      expect(status).to eq(0)
      expect(out).to include("expected additions")
    end

    context "with a project whose Edge row names no template" do
      let(:args) { args_for_project_naming_no_template(@dir) }

      it "refuses without template=, naming the missing setting", :aggregate_failures do
        refused, status = launch(args)

        expect(status).to eq(1)
        expect(refused).to include("template")
      end

      it "takes template= without reading the file", :aggregate_failures do
        out, status = launch([*args, "template=#{@dir}/absent.yaml"])

        expect(status).to eq(0)
        expect(out).to end_with("the live distribution matches the project")
      end
    end

    it "exits 1 when neither of a saved configuration and a distribution is named", :aggregate_failures do
      out, status = launch(["site_projection.check_live", PROJECT])

      expect(status).to eq(1)
      expect(out).to include("exactly one of a saved configuration and a distribution")
    end

    it "exits 1 when both a saved configuration and a distribution are named" do
      _out, status = launch(["site_projection.check_live", PROJECT, "live=x.json", "distribution=E123"])

      expect(status).to eq(1)
    end

    it "fetches the configuration with the one read-only aws call when given a distribution" do
      allow(stubbed_shell).to receive(:capture).with("aws", "cloudfront", "get-distribution-config", "--id", "E36ACSIVZJAKNV")
                                               .and_return(aws_result(JSON.generate(config), "", true))

      expect(launch(["site_projection.check_live", PROJECT, "distribution=E36ACSIVZJAKNV", "refs=#{words}"]).last).to eq(0)
    end

    it "exits 1 with the reason when aws fails", :aggregate_failures do
      stubbed_shell(capture: aws_result("", "AccessDenied", false))
      reason, status = launch(["site_projection.check_live", PROJECT, "distribution=E1"])

      expect(status).to eq(1)
      expect(reason).to include("get-distribution-config failed: AccessDenied")
    end

    it "exits 1 with the reason when the saved file is missing", :aggregate_failures do
      reason, status = launch(["site_projection.check_live", PROJECT, "live=/nonexistent/live.json"])

      expect(status).to eq(1)
      expect(reason).to include("cannot read the live configuration")
    end

    it "exits 1 for a project with no edge", :aggregate_failures do
      FileUtils.mkdir_p(File.join(@dir, "bluebook"))
      reason, status = launch(["site_projection.check_live", @dir, "live=#{@dir}/x.json"])

      expect(status).to eq(1)
      expect(reason).to include("no chapter declares a value_object")
    end
  end
end

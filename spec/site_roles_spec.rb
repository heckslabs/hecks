require "spec_helper"
require "json"
require "webrick"
require "hecks/tools"
require "hecks/tools/site_routes"
require "hecks/projections/site/role_probe"

# The commands a project declares a role for, how a host's answer to each is judged, and
# `site_projection.check_roles` run against a small server that answers as a host enforcing roles
# (or not) would.
RSpec.describe Hecks::Projections::Site::RoleProbe do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/members/domain") }
  let(:registry) { Hecks::Tools::SiteRoutes.registry_for(project) }
  let(:checks) { described_class.checks(registry) }

  it "lists each command that declares a role, as a host is asked to run it", :aggregate_failures do
    expect(checks).not_to be_empty
    expect(checks.map(&:role).uniq).to include("Editor")
    expect(checks.map(&:verb)).to all(match(/\A\w+::\w+\.\w+\z/))
  end

  it "synthesizes the arguments a host checks before it asks who is calling" do
    expect(checks.map(&:arguments)).to all(be_a(Hash))
  end

  describe ".unchecked?" do
    it "is true only when the host refused the arguments themselves", :aggregate_failures do
      expect(described_class.unchecked?({ "refusals" => [{ "kind" => "InvariantViolation" }] })).to be(true)
      expect(described_class.unchecked?({ "refusals" => [{ "kind" => "Unauthorized" }] })).to be(false)
      expect(described_class.unchecked?({ "refusals" => [] })).to be(false)
    end
  end

  describe ".verdict" do
    let(:check) { checks.first }

    it "accepts an Unauthorized refusal and rejects an accepted command or another refusal", :aggregate_failures do
      expect(described_class.verdict(check, { "refusals" => [{ "kind" => "Unauthorized" }] })).to be_nil
      expect(described_class.verdict(check, { "refusals" => [] })).to include("HECKS_ROLE_ENFORCEMENT=enforce")
      expect(described_class.verdict(check, { "refusals" => [{ "kind" => "InvariantViolation" }] }))
        .to include("not as Unauthorized")
    end
  end

  describe "site_projection.check_roles" do
    before(:all) do
      @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
    end

    after { Hecks::Adapters::Codebase::Tree.root = nil }

    def host(enforcing:, refusal: "Unauthorized")
      server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(File::NULL),
                                       AccessLog: [])
      refusals = enforcing ? [{ "kind" => refusal }] : []
      server.mount_proc("/dispatch") { |_req, res| res.body = JSON.generate("refusals" => refusals) }
      thread = Thread.new { server.start }
      yield "http://127.0.0.1:#{server.config[:Port]}"
    ensure
      server.shutdown
      thread&.join
    end

    def run(url)
      Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["site", "site_projection.check_roles", project, "url=#{url}", "--wait"])
    end

    it "passes a host that refuses every command", :aggregate_failures do
      host(enforcing: true) do |url|
        out, status = run(url)

        expect(status).to eq(0)
        expect(out).to include("0 failed")
      end
    end

    it "fails a host that runs a command for a caller with no role", :aggregate_failures do
      host(enforcing: false) do |url|
        out, status = run(url)

        expect(status).to eq(1)
        expect(out).to include("is refused with no role... FAILED: was not refused for its role")
      end
    end

    it "counts a command whose arguments the host refused as unchecked, not failed", :aggregate_failures do
      host(enforcing: true, refusal: "InvariantViolation") do |url|
        out, status = run(url)

        expect(status).to eq(0)
        expect(out).to include("0 failed").and include("unchecked: the host refused the arguments")
      end
    end

    it "refuses to ask a host that is not on this machine", :aggregate_failures do
      out, status = run("https://example.org")

      expect(status).to eq(1)
      expect(out).to include("not example.org")
    end
  end
end

require "spec_helper"
require "webrick"
require "hecks/tools"
require "hecks/tools/site_routes"
require "hecks/projections/site/probe"

# The requests a live site must answer the way its route table says: which a table yields, how
# each answer is judged, and `site_projection.check_site` run against a small server that behaves
# as the sample studio's table declares.
RSpec.describe Hecks::Projections::Site::Probe do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio") }
  let(:rows) do
    registry = Hecks::Tools::SiteRoutes.registry_for(project)
    Hecks::Projections::Site::Table.read(Hecks::Projections::Site::Table.chapter(registry), registry: registry).rows
  end
  let(:probe) { described_class.new(rows, run: "r1") }
  let(:response) { described_class::Response }

  def check_for(path, verb = "GET") = probe.checks.find { |check| check.path == path && check.verb == verb }

  it "asks each admin path with each verb it takes, and leaves out a prefix or a parameter", :aggregate_failures do
    expect(check_for("/admin-inbox").expect).to eq(:refused)
    expect(check_for("/admin-inbox", "POST").expect).to eq(:refused)
    expect(probe.checks.map(&:path)).not_to include("/blog/:slug.html", "/assets/*", "/admin*")
  end

  it "expects a public indexable page to answer 200, and a row that is off to answer 404", :aggregate_failures do
    expect(check_for("/about").expect).to eq(:page)
    expect(check_for("/podcast").expect).to eq(:missing)
    expect(check_for("/inquiry-received")).to be_nil
  end

  it "expects a redirect row to lead to its target, and a path no row declares to be missing", :aggregate_failures do
    expect(check_for("/old-portfolio").to).to eq("/portfolio")
    expect(probe.checks.last.path).to eq("/probe-r1-missing")
  end

  describe "#verdict" do
    def judge(path, status, headers: {}, body: "", verb: "GET")
      probe.verdict(check_for(path, verb), response.new(status: status, headers: headers, body: body))
    end

    it "accepts a refusal that is not cached and rejects one that is, or none", :aggregate_failures do
      expect(judge("/admin-inbox", 302, headers: { "cache-control" => "private, no-store" })).to be_nil
      expect(judge("/admin-inbox", 403)).to be_nil
      expect(judge("/admin-inbox", 302)).to be_nil
      expect(judge("/admin-inbox", 302, headers: { "cache-control" => "public, max-age=60" })).to include("cacheable")
      expect(judge("/admin-inbox", 200)).to include("got HTTP 200")
    end

    it "wants a canonical link on a page, and the target on a redirect", :aggregate_failures do
      expect(judge("/about", 200, body: '<link rel="canonical" href="https://x.test/about">')).to be_nil
      expect(judge("/about", 200, body: "<html></html>")).to include("no canonical link")
      expect(judge("/old-portfolio", 301, headers: { "location" => "/portfolio" })).to be_nil
      expect(judge("/old-portfolio", 301, headers: { "location" => "/elsewhere" })).to include("expected \"/portfolio\"")
    end
  end

  describe "site_projection.check_site" do
    before(:all) do
      @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    end

    after { Hecks::Adapters::Codebase::Tree.root = nil }

    def serve(**broken)
      server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(File::NULL),
                                       AccessLog: [])
      server.mount_proc("/") { |req, res| answer(req.path, res, broken) }
      thread = Thread.new { server.start }
      yield "http://127.0.0.1:#{server.config[:Port]}"
    ensure
      server.shutdown
      thread&.join
    end

    PAGES = %w[/ /about /services /portfolio /blog /contact /terms /privacy].freeze

    def answer(path, res, broken)
      res.status = 404
      if path.start_with?("/admin-", "/Studio/Inquiry/Recent")
        respond(res, broken[:admin_open] ? 200 : 302, "/login", "Cache-Control" => "private, no-store")
      elsif path == "/old-portfolio"
        respond(res, 301, "/portfolio")
      elsif PAGES.include?(path)
        respond(res, 200, nil, body: '<link rel="canonical" href="/">')
      end
    end

    def respond(res, status, location, body: nil, **headers)
      res.status = status
      res["Location"] = location if location
      headers.each { |name, value| res[name.to_s] = value }
      res.body = body if body
    end

    def run(url)
      Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                   argv: ["site", "site_projection.check_site", project, "url=#{url}", "--wait"])
    end

    it "passes a site that answers as its table declares", :aggregate_failures do
      serve do |url|
        out, status = run(url)

        expect(status).to eq(0)
        expect(out).to include("0 failed")
      end
    end

    it "fails a site whose admin page opens to an anonymous caller, naming it", :aggregate_failures do
      serve(admin_open: true) do |url|
        out, status = run(url)

        expect(status).to eq(1)
        expect(out).to include("/admin-inbox without a session is refused and not cached... FAILED")
      end
    end

    it "refuses an address that is not http(s)", :aggregate_failures do
      out, status = run("ftp://example.org")

      expect(status).to eq(1)
      expect(out).to include("SiteUrl")
    end
  end
end

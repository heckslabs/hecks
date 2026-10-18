require "spec_helper"
require "rack/mock"
require "tmpdir"
require "hecks/composer/web"

# The domains the editor can open: every directory of a checkout that holds a bluebook, listed by
# group, and opened as a scratch copy that the editor may change freely. A fake checkout stands in
# for the real one, so the lists are small and exact.
RSpec.describe "the Composer's known domains" do
  let(:root) { Dir.mktmpdir("composer-domains") }

  before do
    write("examples/pizzas/bluebook/pizzas.bluebook", "Hecks.bluebook \"Pizzas\" do\nend\n")
    write("examples/pizzas/bluebook/pizzas.hecksagon", "Hecks.hecksagon \"Pizzas\" do\nend\n")
    write("examples/pizzas/data/orders.heki", "not a declaration")
    write("examples/loose/loose.bluebook", "Hecks.bluebook \"Loose\" do\nend\n")
    write("lib/hecks/site/bluebook/site.bluebook", "Hecks.bluebook \"Site\" do\nend\n")
    write("rust/parser/tests/fixtures/x.bluebook", "Hecks.bluebook \"X\" do\nend\n")
    write("tmp/composer/old/old.bluebook", "Hecks.bluebook \"Old\" do\nend\n")
  end

  after { FileUtils.rm_rf(root) }

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  def domains = Hecks::Composer::Domains

  def ids = domains.known(root: root).map { |entry| entry[:id] }

  it "lists the domains that hold a bluebook, a bluebook folder standing for its domain", :aggregate_failures do
    expect(ids).to eq(%w[examples/loose examples/pizzas lib/hecks/site])
    expect(domains.known(root: root).first).to eq(id: "examples/loose", group: "Examples")
  end

  it "leaves out what no group takes, such as parser fixtures and earlier scratch copies" do
    expect(ids).not_to include("rust/parser/tests/fixtures", "tmp/composer/old")
  end

  it "copies a domain's declaration files into a scratch directory and nothing else", :aggregate_failures do
    scratch = domains.open(root: root, id: "examples/pizzas")

    expect(scratch).to eq(File.join(root, "tmp/composer/examples_pizzas"))
    expect(Dir.children(scratch)).to contain_exactly("pizzas.bluebook", "pizzas.hecksagon")
  end

  it "opens a domain that keeps its bluebooks beside it, with no bluebook folder" do
    scratch = domains.open(root: root, id: "examples/loose")

    expect(Dir.children(scratch)).to eq(["loose.bluebook"])
  end

  it "leaves the real files alone when the copy is changed", :aggregate_failures do
    scratch = domains.open(root: root, id: "examples/pizzas")
    File.write(File.join(scratch, "pizzas.bluebook"), "changed")

    expect(File.read(File.join(root, "examples/pizzas/bluebook/pizzas.bluebook"))).to include("Pizzas")
    expect(File.read(File.join(scratch, "pizzas.bluebook"))).to eq("changed")
  end

  it "replaces an earlier copy of the same domain" do
    scratch = domains.open(root: root, id: "examples/pizzas")
    File.write(File.join(scratch, "stray.bluebook"), "")

    expect(Dir.children(domains.open(root: root, id: "examples/pizzas"))).not_to include("stray.bluebook")
  end

  it "refuses an id that is not on the list, including a path of its own", :aggregate_failures do
    expect { domains.open(root: root, id: "examples/missing") }.to raise_error(domains::Unknown)
    expect { domains.open(root: root, id: "../../etc") }.to raise_error(domains::Unknown, /not a domain/)
  end

  describe "through the Rack app" do
    let(:request) { Rack::MockRequest.new(Hecks::Composer::Web.app(workspace: root, root: root)) }

    def get(path) = JSON.parse(request.get("/composer/#{path}").body)

    def open_domain(id) = request.post("/composer/open", input: JSON.generate(id: id))

    it "lists the known domains with the group of each", :aggregate_failures do
      listed = get("domains")["domains"]

      expect(listed.map { |entry| entry["id"] }).to eq(ids)
      expect(listed.map { |entry| entry["group"] }.uniq).to eq(["Examples", "Hecks chapters"])
    end

    it "switches to a domain's scratch copy, so its files are the ones listed next", :aggregate_failures do
      expect(open_domain("examples/pizzas").status).to eq(200)
      expect(get("files")["files"].map { |file| file["path"] }).to contain_exactly("pizzas.bluebook", "pizzas.hecksagon")
      expect(get("domains")["current"]).to eq("examples_pizzas")
    end

    it "answers 404 for a domain that is not on the list" do
      expect(open_domain("../../etc").status).to eq(404)
    end
  end
end

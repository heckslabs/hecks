require "spec_helper"
require "tmpdir"
require "rack/mock"
require "hecks/hecks/adapters/codebase/previewing"
require "hecks/hecks/adapters/codebase/tree"

# `corpus_run.preview`: serves one directory of static files on the loopback address only.
RSpec.describe Hecks::Adapters::Codebase::Previewing do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:site) { Dir.mktmpdir("preview_site") }
  let(:served) { [] }

  before do
    File.write(File.join(site, "index.html"), "home")
    File.write(File.join(site, "about.html"), "about")
    File.write(File.join(File.dirname(site), "secret.txt"), "outside")
    served_into = served
    allow(Hecks::Adapters::Codebase::CorpusTasks).to receive(:web_server).and_return(->(**args) { served_into << args })
    allow($stderr).to receive(:write)
  end

  after { FileUtils.rm_rf([site, File.join(File.dirname(site), "secret.txt")]) }

  def preview(**fields) = described_class.call("preview", fields.transform_values { |value| { value: value } }, tree)

  def get(path) = Rack::MockRequest.new(served.first[:app]).get(path)

  it "binds the loopback address on the default port", :aggregate_failures do
    preview(directory: site)

    expect(served.first).to include(host: "127.0.0.1", port: 4580)
  end

  it "answers the root with index.html and a clean URL with its .html file", :aggregate_failures do
    preview(directory: site)

    expect([get("/").body, get("/about").body]).to eq(%w[home about])
  end

  it "does not leave the directory" do
    preview(directory: site)

    expect(get("/../secret.txt").status).to eq(404)
  end

  it "answers GET and HEAD only" do
    preview(directory: site)

    expect(Rack::MockRequest.new(served.first[:app]).post("/").status).to eq(405)
  end

  it "refuses a directory that is not one" do
    expect { preview(directory: File.join(site, "missing")) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /naming a directory/)
  end
end

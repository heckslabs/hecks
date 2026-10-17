require "spec_helper"
require "json"
require "open3"
require "tmpdir"
require "hecks/tools"
require "hecks/tools/site_routes"

# Runs the JavaScript the `redirect_host` kind generates, under node, against stub CloudFront
# events (spec/fixtures/site/edge_function_cases.js). The logic is exercised without publishing a
# function; what CloudFront itself hands the function (how it presents a query string) is not.
# Skipped, with the reason, where `node` is not installed.
RSpec.describe "the generated redirect_host function, under node" do
  let(:code)  { Hecks::Projections::Site::Edge::FunctionCode }
  let(:cases) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/edge_function_cases.js") }
  let(:fixture_function) do
    registry = Hecks::Tools::SiteRoutes.registry_for(File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio"))
    chapter = Hecks::Projections::Site::Table.chapter(registry)
    table = Hecks::Projections::Site::Table.read(chapter, registry: registry)
    vocabulary = Hecks::Projections::Site::Table.vocabulary(registry)
    Hecks::Projections::Site::Edge.read(chapter, table: table, vocabulary: vocabulary).function("HostRedirect")
  end

  before do
    skip "node is not on the PATH; the generated function is not run here" unless node?
  end

  def node? = system("node", "--version", out: File::NULL, err: File::NULL)

  # Writes the function for `function` and returns what the cases file reports for it.
  def report_for(function, &mutate)
    Dir.mktmpdir("edge_function") do |dir|
      file = File.join(dir, "function.js")
      File.write(file, (mutate || :itself.to_proc).call(code.code(function)))
      run_cases(file, JSON.generate(canonical: function.host, aliases: function.alias_list, paths: function.path_list))
    end
  end

  def run_cases(file, config)
    out, err, status = Open3.capture3("node", cases, file, config)
    raise "node failed: #{err}" unless status.success?

    JSON.parse(out)
  end

  def failures(report) = report.reject { |entry| entry["ok"] }.map { |entry| "#{entry["name"]}: #{entry["error"]}" }

  it "passes every case for the sample project's function", :aggregate_failures do
    report = report_for(fixture_function)

    expect(report.size).to be >= 24
    expect(failures(report)).to be_empty
  end

  it "passes every case for a function with an apex and a www alias", :aggregate_failures do
    function = fixture_function.dup.tap { |copy| copy.aliases = "example.test,www.example.test" }
    report = report_for(function)

    expect(report.size).to be >= 24
    expect(failures(report)).to be_empty
  end

  it "fails the cases for a function that drops the no-store header (the cases can fail)", :aggregate_failures do
    report = report_for(fixture_function) { |text| text.sub('"no-store"', '"public"') }

    expect(failures(report).first).to start_with("is never cached")
    expect(failures(report).size).to eq(1)
  end

  it "fails the cases for a function that redirects every method" do
    report = report_for(fixture_function) { |text| text.sub(/var reads = .*;/, "var reads = true;") }

    expect(failures(report).join).to include("passes POST through untouched")
  end
end

require "spec_helper"
require "hecks_cli"
require "json"

# Hecks CLI inspect --format json spec
#
# Verifies that `hecks inspect --format json` outputs a valid JSON
# document with domain structure suitable for tooling.
RSpec.describe "hecks inspect --format json" do
  let(:cli) { Hecks::CLI.new }

  before { allow($stdout).to receive(:puts) }

  it "outputs valid JSON with full domain structure" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestBluebook"), <<~RUBY)
        Hecks.domain "Shop" do
          aggregate "Order" do
            attribute :name, String
            attribute :total, Float

            value_object "LineItem" do
              attribute :product, String
            end

            command "CreateOrder" do
              attribute :name, String
            end

            event "OrderCreated"
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_inspect_json(dir)
        parsed = JSON.parse(output)
        expect(parsed["domain"]).to eq("Shop")
        agg = parsed["aggregates"].first
        expect(agg["name"]).to eq("Order")
        expect(agg["attributes"].map { |a| a["name"] }).to include("name", "total")
        expect(agg["commands"].first["name"]).to eq("CreateOrder")
        expect(agg["events"]).to include("OrderCreated")
        expect(agg["value_objects"]).to include("LineItem")
      end
    end
  end

  it "filters to a single aggregate" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestBluebook"), <<~RUBY)
        Hecks.domain "Multi" do
          aggregate "Foo" do
            attribute :x, String
            command "CreateFoo" do
              attribute :x, String
            end
          end
          aggregate "Bar" do
            attribute :y, String
            command "CreateBar" do
              attribute :y, String
            end
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_inspect_json(dir, aggregate: "Foo")
        parsed = JSON.parse(output)
        expect(parsed["aggregates"].size).to eq(1)
        expect(parsed["aggregates"].first["name"]).to eq("Foo")
      end
    end
  end

  def capture_inspect_json(domain_path, aggregate: nil)
    opts = { domain: domain_path, format: "json" }
    opts[:aggregate] = aggregate if aggregate
    allow(cli).to receive(:options).and_return(opts)
    output = StringIO.new
    allow(cli.shell).to receive(:say) { |msg, *| output.puts(msg) }
    cli.inspect
    output.string
  end
end

require "spec_helper"
require "hecks_cli"

# Hecks CLI inspect command spec
#
# Verifies that `hecks inspect` produces terminal output covering
# all major domain IR sections: attributes, lifecycle, policies,
# invariants, value objects, commands, and events.
RSpec.describe "hecks inspect" do
  let(:cli) { Hecks::CLI.new }

  before { allow($stdout).to receive(:puts) }

  it "shows full domain definition with all sections" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestBluebook"), <<~RUBY)
        Hecks.domain "Shop" do
          aggregate "Order" do
            attribute :name, String
            attribute :status, String

            value_object "LineItem" do
              attribute :product, String
              attribute :qty, Integer
            end

            invariant "name must be present" do
              !name.nil? && !name.empty?
            end

            lifecycle :status, default: "draft" do
              transition "PlaceOrder" => "placed"
            end

            command "CreateOrder" do
              attribute :name, String
            end

            command "PlaceOrder" do
              reference_to "Order"
            end

            policy "HighValue" do |cmd|
              cmd.respond_to?(:name)
            end
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_inspect_output(dir)
        expect(output).to include("Domain: Shop")
        expect(output).to include("Aggregate: Order")
        expect(output).to include("name: String")
        expect(output).to include("LineItem")
        expect(output).to include("Lifecycle:")
        expect(output).to include("draft")
        expect(output).to include("CreateOrder")
        expect(output).to include("Invariants:")
        expect(output).to include("name must be present")
        expect(output).to include("Policies:")
      end
    end
  end

  it "shows computed attributes" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestBluebook"), <<~RUBY)
        Hecks.domain "Realty" do
          aggregate "Property" do
            attribute :area, Float

            computed :lot_size do
              area / 43560.0
            end
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_inspect_output(dir)
        expect(output).to include("Computed Attributes:")
        expect(output).to include("lot_size:")
        expect(output).to include("area / 43560.0")
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
        output = capture_inspect_output(dir, aggregate: "Foo")
        expect(output).to include("Foo")
        expect(output).not_to include("Aggregate: Bar")
      end
    end
  end

  def capture_inspect_output(domain_path, aggregate: nil)
    allow(cli).to receive(:options).and_return(
      { domain: domain_path, aggregate: aggregate }
    )
    output = StringIO.new
    allow(cli.shell).to receive(:say) { |msg, *| output.puts(msg) }
    cli.inspect
    output.string
  end
end

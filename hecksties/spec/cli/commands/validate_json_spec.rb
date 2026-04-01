require "spec_helper"
require "hecks_cli"
require "json"

# Hecks CLI validate --format json spec
#
# Verifies that `hecks validate --format json` outputs a valid JSON
# document with domain validation results suitable for tooling.
RSpec.describe "hecks validate --format json" do
  let(:cli) { Hecks::CLI.new }

  before { allow($stdout).to receive(:puts) }

  it "outputs valid JSON for a valid domain" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PizzasBluebook"), <<~RUBY)
        Hecks.domain "Test" do
          aggregate "Widget" do
            attribute :name, String
            command "CreateWidget" do
              attribute :name, String
            end
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_validate_json(dir)
        parsed = JSON.parse(output)
        expect(parsed["valid"]).to be true
        expect(parsed["domain"]).to eq("Test")
        expect(parsed["aggregates"].first["name"]).to eq("Widget")
        expect(parsed["aggregates"].first["commands"]).to include("CreateWidget")
        expect(parsed["errors"]).to eq([])
      end
    end
  end

  it "includes errors for invalid domain" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PizzasBluebook"), <<~RUBY)
        Hecks.domain "Test" do
          aggregate "Widget" do
            attribute :name, String
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_validate_json(dir)
        parsed = JSON.parse(output)
        expect(parsed["valid"]).to be false
        expect(parsed["errors"]).not_to be_empty
      end
    end
  end

  def capture_validate_json(domain_path)
    allow(cli).to receive(:options).and_return(
      { domain: domain_path, format: "json" }
    )
    output = StringIO.new
    allow(cli.shell).to receive(:say) { |msg, *| output.puts(msg) }
    cli.validate
    output.string
  end
end

require "spec_helper"
require "hecks_cli"

# Hecks CLI glossary command spec
#
# Verifies that `hecks glossary` prints the domain glossary to stdout
# and that `--export` writes glossary.md to disk.
RSpec.describe "hecks glossary" do
  let(:cli) { Hecks::CLI.new }

  before { allow($stdout).to receive(:puts) }

  it "prints glossary to stdout" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestBluebook"), <<~RUBY)
        Hecks.domain "Shop" do
          glossary do
            define "order", as: "A customer request to purchase items"
            prefer "customer", not: ["user"]
          end
          aggregate "Order" do
            attribute :name, String
            command "CreateOrder" do
              attribute :name, String
            end
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_glossary_output(dir)
        expect(output).to include("Shop Domain Glossary")
        expect(output).to include("Ubiquitous Language")
        expect(output).to include("**order** -- A customer request to purchase items")
        expect(output).to include("**customer**")
        expect(output).to include("avoid: user")
      end
    end
  end

  it "exports glossary.md with --export" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestBluebook"), <<~RUBY)
        Hecks.domain "Shop" do
          aggregate "Order" do
            attribute :name, String
            command "CreateOrder" do
              attribute :name, String
            end
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_glossary_output(dir, export: true)
        expect(output).to include("Wrote")
        expect(File.exist?(File.join(dir, "glossary.md"))).to be true
        content = File.read(File.join(dir, "glossary.md"))
        expect(content).to include("Shop Domain Glossary")
      end
    end
  end

  def capture_glossary_output(domain_path, export: false)
    allow(cli).to receive(:options).and_return(
      { domain: domain_path, export: export }
    )
    output = StringIO.new
    allow(cli.shell).to receive(:say) { |msg, *| output.puts(msg) }
    cli.glossary
    output.string
  end
end

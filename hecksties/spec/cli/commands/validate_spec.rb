require "spec_helper"
require "hecks_cli"

RSpec.describe "hecks validate" do
  let(:cli) { Hecks::CLI.new }

  before { allow($stdout).to receive(:puts) }

  it "reports valid domain with aggregate summary" do
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
        output = capture_output { cli.validate }
        expect(output).to include("Domain is valid")
        expect(output).to include("Widget")
      end
    end
  end

  it "reports validation errors" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PizzasBluebook"), <<~RUBY)
        Hecks.domain "Test" do
          aggregate "Widget" do
            attribute :name, String
          end
        end
      RUBY
      Dir.chdir(dir) do
        output = capture_output { cli.validate }
        expect(output).to include("failed") | include("no commands")
      end
    end
  end

  def capture_output
    output = StringIO.new
    cli.instance_variable_set(:@shell, Thor::Shell::Basic.new)
    allow(cli.shell).to receive(:say) { |msg, *| output.puts(msg) }
    cli.validate
    output.string
  end
end

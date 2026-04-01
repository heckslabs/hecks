require "spec_helper"
require "hecks_cli"

RSpec.describe "hecks interview" do
  before { allow($stdout).to receive(:puts) }

  it "builds a domain from scripted answers" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        cli = Hecks::CLI.new
        allow(cli).to receive(:say)

        # Script: domain name, aggregate name, attributes, commands, then confirm
        answers = [
          "Pizzas",          # domain name
          "Pizza",           # aggregate name
          "name:String",     # attribute
          "size:String",     # attribute
          "",                # done with attributes
          "CreatePizza",     # command
          "",                # done with commands
          "",                # done with aggregates
          "Y"                # confirm
        ]
        call_count = 0
        allow(cli).to receive(:ask) { answers[call_count].tap { call_count += 1 } }

        cli.interview

        bluebook = File.join(dir, "PizzasBluebook")
        expect(File.exist?(bluebook)).to be true

        content = File.read(bluebook)
        expect(content).to include('Hecks.domain "Pizzas"')
        expect(content).to include('aggregate "Pizza"')
        expect(content).to include("attribute :name, String")
        expect(content).to include("attribute :size, String")
        expect(content).to include('command "CreatePizza"')
      end
    end
  end

  it "cancels when user declines confirmation" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        cli = Hecks::CLI.new
        allow(cli).to receive(:say)

        answers = ["Pizzas", "Pizza", "name:String", "", "CreatePizza", "", "", "n"]
        call_count = 0
        allow(cli).to receive(:ask) { answers[call_count].tap { call_count += 1 } }

        cli.interview

        expect(Dir[File.join(dir, "*Bluebook")]).to be_empty
      end
    end
  end

  it "reprompts on blank domain name" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        cli = Hecks::CLI.new
        allow(cli).to receive(:say)

        answers = ["", "Orders", "Order", "total:Integer", "", "PlaceOrder", "", "", "Y"]
        call_count = 0
        allow(cli).to receive(:ask) { answers[call_count].tap { call_count += 1 } }

        cli.interview

        bluebook = File.join(dir, "OrdersBluebook")
        expect(File.exist?(bluebook)).to be true
        expect(File.read(bluebook)).to include('Hecks.domain "Orders"')
      end
    end
  end
end

require "spec_helper"

RSpec.describe "CLI domain resolution" do
  describe "find_installed_domains" do
    it "finds gems with Bluebook" do
      cli = Hecks::CLI.new
      domains = cli.send(:find_installed_domains)
      # pizzas_domain should be installed from our test setup
      names = domains.map(&:first)
      expect(names).to include("pizzas_domain") if Gem::Specification.any? { |s| s.name == "pizzas_domain" }
    end
  end

  describe "resolve_domain_option auto-selection" do
    let(:cli) { Hecks::CLI.new }

    before { allow(cli).to receive(:find_domain_file).and_return(nil) }

    context "when no installed domains" do
      it "aborts with a helpful message" do
        allow(cli).to receive(:find_installed_domains).and_return([])
        expect { cli.send(:resolve_domain_option) }.to raise_error(SystemExit)
      end
    end

    context "when exactly one installed domain" do
      it "auto-selects and prints a message" do
        allow(cli).to receive(:find_installed_domains).and_return([["pizzas_domain", ["1.0.0"]]])
        allow(cli).to receive(:say)
        expect(cli).to receive(:resolve_domain).with("pizzas_domain")
        cli.send(:resolve_domain_option)
      end
    end

    context "when multiple installed domains" do
      it "shows a numbered list and resolves the selection" do
        allow(cli).to receive(:find_installed_domains).and_return([
          ["pizzas_domain", ["1.0.0"]],
          ["banking_domain", ["2.0.0"]]
        ])
        allow(cli).to receive(:say)
        allow(cli).to receive(:ask).and_return("1")
        expect(cli).to receive(:resolve_domain).with("pizzas_domain")
        cli.send(:resolve_domain_option)
      end
    end
  end

  describe "resolve_domain" do
    let(:cli) { Hecks::CLI.new }

    it "resolves from a directory with Bluebook" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "PizzasBluebook"), 'Hecks.domain("Test") { aggregate("Thing") { attribute :name, String; command("CreateThing") { attribute :name, String } } }')
        domain = cli.send(:resolve_domain, dir)
        expect(domain.name).to eq("Test")
      end
    end

    it "returns nil for nonexistent path" do
      domain = cli.send(:resolve_domain, "/nonexistent/path")
      expect(domain).to be_nil
    end
  end
end

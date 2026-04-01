require "spec_helper"
require "hecks_cli"

RSpec.describe "hecks diff" do
  before { allow($stdout).to receive(:puts) }

  it "detects added aggregates as non-breaking" do
    Dir.mktmpdir do |dir|
      # Save a snapshot of the "old" domain
      old_domain = Hecks.domain("Test") do
        aggregate "Widget" do
          attribute :name, String
          command "CreateWidget" do
            attribute :name, String
          end
        end
      end
      snapshot_path = File.join(dir, ".hecks_domain_snapshot.rb")
      Hecks::Migrations::DomainSnapshot.save(old_domain, path: snapshot_path)

      # Write a "new" domain with an added aggregate
      File.write(File.join(dir, "PizzasBluebook"), <<~RUBY)
        Hecks.domain "Test" do
          aggregate "Widget" do
            attribute :name, String
            command "CreateWidget" do
              attribute :name, String
            end
          end
          aggregate "Gadget" do
            attribute :label, String
            command "CreateGadget" do
              attribute :label, String
            end
          end
        end
      RUBY

      Dir.chdir(dir) do
        cli = Hecks::CLI.new
        messages = []
        allow(cli).to receive(:say) { |msg, color| messages << [msg, color] }

        stub_const("Hecks::Migrations::DomainSnapshot::DEFAULT_PATH", snapshot_path)
        cli.diff

        text = messages.map(&:first).join("\n")
        expect(text).to include("+ aggregate: Gadget")
        # Added aggregate is not breaking
        expect(text).not_to include("BREAKING")
      end
    end
  end

  it "detects removed attributes as breaking" do
    Dir.mktmpdir do |dir|
      old_domain = Hecks.domain("Test") do
        aggregate "Widget" do
          attribute :name, String
          attribute :color, String
          command "CreateWidget" do
            attribute :name, String
          end
        end
      end
      snapshot_path = File.join(dir, ".hecks_domain_snapshot.rb")
      Hecks::Migrations::DomainSnapshot.save(old_domain, path: snapshot_path)

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
        cli = Hecks::CLI.new
        messages = []
        allow(cli).to receive(:say) { |msg, color| messages << [msg, color] }

        stub_const("Hecks::Migrations::DomainSnapshot::DEFAULT_PATH", snapshot_path)
        cli.diff

        text = messages.map(&:first).join("\n")
        expect(text).to include("- attribute:")
        expect(text).to include("BREAKING")
      end
    end
  end
end

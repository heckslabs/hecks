require "spec_helper"
require "hecks_cli"

RSpec.describe "hecks build" do
  before { allow($stdout).to receive(:puts) }

  it "builds a domain gem from Bluebook" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "verbs.txt"), "Create\n")
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
        allow(cli).to receive(:say)
        cli.build

        gem_dir = File.join(dir, "test_domain")
        expect(Dir.exist?(gem_dir)).to be true
        expect(File.exist?(File.join(gem_dir, "test_domain.gemspec"))).to be true
        expect(File.exist?(File.join(gem_dir, "lib", "test_domain.rb"))).to be true
      end
    end
  end
end

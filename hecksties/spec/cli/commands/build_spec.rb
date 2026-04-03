require "spec_helper"
require "hecks_cli"

RSpec.describe "hecks build", :slow do
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

  it "produces a .gem artifact with --gem flag" do
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
        cli = Hecks::CLI.new([], gem: true)
        messages = []
        allow(cli).to receive(:say) { |msg, *| messages << msg }
        cli.build

        gem_dir = File.join(dir, "test_domain")
        gem_files = Dir.glob(File.join(gem_dir, "*.gem"))
        expect(gem_files).not_to be_empty, "Expected a .gem file in #{gem_dir}"
        expect(messages).to include(match(/Gem artifact:/))
      end
    end
  end

  it "warns when --gem is used with a non-ruby target" do
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
        # Register a fake target so the build succeeds without extra deps
        Hecks.target_registry.register(:fake, ->(_domain, **_opts) { dir })
        cli = Hecks::CLI.new([], gem: true, target: "fake")
        messages = []
        allow(cli).to receive(:say) { |msg, *| messages << msg }
        cli.build

        expect(messages).to include("--gem is only supported for ruby and static targets")
      end
    end
  end
end

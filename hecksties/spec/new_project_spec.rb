require "spec_helper"
require "fileutils"
require "tmpdir"
require "stringio"
require "hecks_cli"

RSpec.describe "hecks new CLI command" do
  let(:tmpdir) { Dir.mktmpdir("hecks-new-") }
  after { FileUtils.rm_rf(tmpdir) }

  it "generates project files" do
    Dir.chdir(tmpdir) do
      cli = Hecks::CLI.new([], { "no-world-goals": true })
      cli.invoke(:new_project, ["my_app"])

      expect(Dir["my_app/*Bluebook"].any?).to be true
      expect(File.exist?("my_app/app.rb")).to be true
      expect(File.exist?("my_app/Gemfile")).to be true
      expect(File.exist?("my_app/spec/spec_helper.rb")).to be true
      expect(File.exist?("my_app/.gitignore")).to be true
      expect(File.exist?("my_app/.rspec")).to be true
    end
  end

  it "uses PascalCase for the domain name" do
    Dir.chdir(tmpdir) do
      cli = Hecks::CLI.new([], { "no-world-goals": true })
      cli.invoke(:new_project, ["my_cool_app"])

      bluebook = Dir["my_cool_app/*Bluebook"].first
      content = File.read(bluebook)
      expect(content).to include('"MyCoolApp"')
    end
  end

  it "refuses to overwrite an existing directory" do
    Dir.chdir(tmpdir) do
      FileUtils.mkdir_p("existing")
      cli = Hecks::CLI.new([], { "no-world-goals": true })
      expect {
        cli.invoke(:new_project, ["existing"])
      }.not_to raise_error
      expect(File.exist?("existing/app.rb")).to be false
    end
  end

  it "generates a valid domain that can be booted" do
    Dir.chdir(tmpdir) do
      cli = Hecks::CLI.new([], { "no-world-goals": true })
      cli.invoke(:new_project, ["bootable"])
    end

    bluebook = Dir[File.join(tmpdir, "bootable/*Bluebook")].first
    domain_content = File.read(bluebook)
    domain = eval(domain_content, TOPLEVEL_BINDING, bluebook, 1)
    valid, errors = Hecks.validate(domain)
    expect(valid).to be(true), "Generated domain is invalid: #{errors.join(', ')}"
  end

  context "world goals onboarding" do
    def with_stdin(text)
      fake = StringIO.new(text)
      allow(fake).to receive(:tty?).and_return(true)
      original = $stdin
      $stdin = fake
      yield
    ensure
      $stdin = original
    end

    it "--no-world-goals flag skips prompt entirely and generates plain domain" do
      Dir.chdir(tmpdir) do
        cli = Hecks::CLI.new([], { "no-world-goals": true })
        cli.invoke(:new_project, ["ci_domain"])

        bluebook = File.read(Dir["ci_domain/*Bluebook"].first)
        expect(bluebook).not_to include("world_concerns")
        expect(bluebook).not_to include("extend :")
      end
    end

    it "choice 2 (skip) generates plain domain without world_concerns" do
      Dir.chdir(tmpdir) do
        with_stdin("2\n") do
          Hecks::CLI.new.invoke(:new_project, ["skip_domain"])
        end
        bluebook = File.read(Dir["skip_domain/*Bluebook"].first)
        expect(bluebook).not_to include("world_concerns")
        expect(bluebook).not_to include("extend :")
      end
    end

    it "choice 3 (doesn't apply) generates domain with commented stub" do
      Dir.chdir(tmpdir) do
        with_stdin("3\n") do
          Hecks::CLI.new.invoke(:new_project, ["stub_domain"])
        end
        bluebook = File.read(Dir["stub_domain/*Bluebook"].first)
        expect(bluebook).to include("# world_concerns :privacy, :consent  # add when ready")
        expect(bluebook).not_to include("\n  world_concerns ")
      end
    end

    it "choice 1 with privacy and consent generates world_concerns and deduped extend calls" do
      Dir.chdir(tmpdir) do
        with_stdin("1\nprivacy, consent\n") do
          Hecks::CLI.new.invoke(:new_project, ["values_domain"])
        end
        bluebook = File.read(Dir["values_domain/*Bluebook"].first)
        expect(bluebook).to include("world_concerns :privacy, :consent")
        expect(bluebook).to include("extend :pii")
        expect(bluebook).to include("extend :auth")
        # auth appears only once even though consent and security both map to it
        expect(bluebook.scan("extend :auth").length).to eq(1)
      end
    end

    it "choice 1 filters invalid goal names and keeps valid ones" do
      Dir.chdir(tmpdir) do
        with_stdin("1\ntransparency bogus consent\n") do
          Hecks::CLI.new.invoke(:new_project, ["filtered_domain"])
        end
        bluebook = File.read(Dir["filtered_domain/*Bluebook"].first)
        expect(bluebook).to include("world_concerns :transparency, :consent")
        expect(bluebook).not_to include("bogus")
        expect(bluebook).to include("extend :audit")
        expect(bluebook).to include("extend :auth")
      end
    end

    it "choice 1 with all six goals deduplicates auth extension" do
      Dir.chdir(tmpdir) do
        with_stdin("1\nprivacy, transparency, consent, security, equity, sustainability\n") do
          Hecks::CLI.new.invoke(:new_project, ["all_goals_domain"])
        end
        bluebook = File.read(Dir["all_goals_domain/*Bluebook"].first)
        expect(bluebook).to include("world_concerns :privacy, :transparency, :consent, :security, :equity, :sustainability")
        expect(bluebook).to include("extend :pii")
        expect(bluebook).to include("extend :audit")
        expect(bluebook).to include("extend :auth")
        expect(bluebook).to include("extend :tenancy")
        expect(bluebook).to include("extend :rate_limit")
        expect(bluebook.scan("extend :auth").length).to eq(1)
      end
    end

    it "skips prompt in non-interactive mode" do
      allow($stdin).to receive(:tty?).and_return(false)

      Dir.chdir(tmpdir) do
        Hecks::CLI.new.invoke(:new_project, ["noninteractive"])

        bluebook = File.read(Dir["noninteractive/*Bluebook"].first)
        expect(bluebook).not_to include("world_concerns")
      end
    end
  end
end

require "fileutils"
require "tmpdir"
require "hecks/release/gem_pin"

RSpec.describe Hecks::Release::GemPin do
  # Stands in for RubyGems, which publishes these versions.
  let(:published) do
    all = %w[2.1.0 2.3.0 3.0.0 3.1.0.pre].map { |version| Gem::Version.new(version) }
    instance_double(Hecks::Release::GemPin::PublishedVersions).tap do |rubygems|
      allow(rubygems).to receive(:include?) { |version| all.include?(Gem::Version.new(version)) }
      allow(rubygems).to receive(:newest_satisfying) do |requirement|
        all.reject(&:prerelease?).select { |version| requirement.satisfied_by?(version) }.max
      end
    end
  end
  let(:scratch) { Dir.mktmpdir("hecks-gem-pin-spec") }
  let(:root) { File.join(scratch, "tree") }
  let(:pin) { described_class.new(published: published) }

  after { FileUtils.remove_entry(scratch) }

  def tree(files)
    files.each do |path, body|
      full = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end
  end

  def lock(version, section: "GEM")
    "#{section}\n  remote: https://rubygems.org/\n  specs:\n    hecks (#{version})\n    sinatra (4.0.0)\n\n" \
      "PLATFORMS\n  arm64-darwin\n"
  end

  it "reads the locked version when there is a lockfile" do
    tree("site/Gemfile" => %(gem "hecks", "~> 2.1"\n), "site/Gemfile.lock" => lock("2.1.0"))

    expect(pin.resolve(root).version).to eq("2.1.0")
  end

  it "takes the newest published release the constraint allows when there is no lockfile" do
    tree("site/Gemfile" => %(gem "hecks", "~> 2.1"\ngem "pg"\n))

    expect(pin.resolve(root).version).to eq("2.3.0")
  end

  it "ignores a prerelease when choosing from a constraint" do
    tree("Gemfile" => %(gem "hecks", ">= 3.0"\n))

    expect(pin.resolve(root).version).to eq("3.0.0")
  end

  it "accepts a locked prerelease that RubyGems does publish" do
    tree("Gemfile" => %(gem "hecks"\n), "Gemfile.lock" => lock("3.1.0.pre"))

    expect(pin.resolve(root).version).to eq("3.1.0.pre")
  end

  it "refuses a locked version RubyGems has never published" do
    tree("Gemfile" => %(gem "hecks"\n), "Gemfile.lock" => lock("9.9.9"))

    expect { pin.resolve(root) }.to raise_error(described_class::Error, /hecks 9\.9\.9 is not published/)
  end

  %w[path git github branch].each do |option|
    it "refuses hecks taken from #{option}:" do
      tree("Gemfile" => %(gem "hecks", #{option}: "somewhere"\n))

      expect { pin.resolve(root) }.to raise_error(described_class::Error, /not from RubyGems/)
    end
  end

  it "ignores a commented-out path line" do
    tree("Gemfile" => %(# gem "hecks", path: "../hecks"\ngem "hecks", "~> 2.1"\n))

    expect(pin.resolve(root).version).to eq("2.3.0")
  end

  it "refuses a lockfile that resolves hecks from a path" do
    tree("Gemfile" => %(gem "hecks"\n), "Gemfile.lock" => lock("2.1.0", section: "PATH"))

    expect { pin.resolve(root) }.to raise_error(described_class::Error, /PATH source/)
  end

  it "refuses a project that does not use hecks" do
    tree("Gemfile" => %(gem "sinatra"\n))

    expect { pin.resolve(root) }.to raise_error(described_class::Error, /not a Hecks project/)
  end

  it "refuses a constraint no published release satisfies" do
    tree("Gemfile" => %(gem "hecks", "~> 7.0"\n))

    expect { pin.resolve(root) }.to raise_error(described_class::Error, /no published hecks release satisfies/)
  end

  it "lets Gemfiles pin different published versions, reporting the newest and every pin", :aggregate_failures do
    tree("a/Gemfile" => %(gem "hecks", "~> 2.1"\n), "a/Gemfile.lock" => lock("2.1.0"),
         "b/Gemfile" => %(gem "hecks", "~> 3.0"\n))

    resolved = pin.resolve(root)

    expect(resolved.version).to eq("3.0.0")
    expect(resolved.pins).to eq("a/Gemfile" => "2.1.0", "b/Gemfile" => "3.0.0")
  end

  it "refuses when any one Gemfile pins an unpublished version, and names it" do
    tree("a/Gemfile" => %(gem "hecks", "~> 2.1"\n), "b/Gemfile" => %(gem "hecks"\n),
         "b/Gemfile.lock" => lock("9.9.9"))

    expect { pin.resolve(root) }
      .to raise_error(described_class::Error, %r{hecks 9\.9\.9 is not published on RubyGems \(b/Gemfile\)})
  end

  it "ignores a Gemfile under node_modules" do
    tree("site/Gemfile" => %(gem "hecks", "~> 2.1"\n), "site/node_modules/dep/Gemfile" => %(gem "hecks", path: "x"\n))

    expect(pin.resolve(root).version).to eq("2.3.0")
  end

  describe Hecks::Release::GemPin::PublishedVersions do
    subject(:versions) { described_class.new }

    def response_for(body, code: "200")
      Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "").tap do |response|
        allow(response).to receive(:body).and_return(body)
      end
    end

    context "when RubyGems lists a release and a prerelease" do
      before do
        listing = JSON.generate([{ "number" => "2.3.0" }, { "number" => "3.1.0.pre" }])
        allow(Net::HTTP).to receive(:start).and_return(response_for(listing))
      end

      it "answers from the listing" do
        expect([versions.include?("2.3.0"), versions.include?("9.9.9")]).to eq([true, false])
      end

      it "picks the newest release a requirement allows" do
        expect(versions.newest_satisfying(Gem::Requirement.new(">= 2"))).to eq(Gem::Version.new("2.3.0"))
      end

      it "asks only once" do
        versions.include?("2.3.0")
        versions.newest_satisfying(Gem::Requirement.new(">= 2"))

        expect(Net::HTTP).to have_received(:start).once
      end
    end

    it "reports a refusal from RubyGems" do
      allow(Net::HTTP).to receive(:start).and_return(response_for("", code: "503"))

      expect { versions.include?("2.3.0") }
        .to raise_error(Hecks::Release::GemPin::Error, /RubyGems answered 503/)
    end

    it "reports an unreachable RubyGems without a stack of socket detail" do
      allow(Net::HTTP).to receive(:start).and_raise(SocketError)

      expect { versions.include?("2.3.0") }
        .to raise_error(Hecks::Release::GemPin::Error, /could not reach RubyGems.*SocketError/)
    end
  end
end

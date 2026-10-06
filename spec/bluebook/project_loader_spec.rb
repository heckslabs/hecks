require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::Bluebook::ProjectLoader do
  around do |example|
    @root = Dir.mktmpdir("hecks-project-loader-")
    example.run
  ensure
    FileUtils.remove_entry(@root) if @root
  end

  context "with catalog and billing domains on disk" do
    let(:register) { described_class.load(@root) }

    before do
      write_domain("catalog", "Catalog", "Book", "Add", query: "Available")
      write_domain("billing", "Billing", "Invoice", "Issue")
    end

    it "crawls Bluebook folders and registers commands and snake_case queries" do
      expect(register.entries.keys).to contain_exactly(
        "Acme::Billing::Invoice.Issue", "Acme::Catalog::Book.Add", "Acme::Catalog::Book.available"
      )
    end

    it "registers a query under its snake_case name" do
      expect(register.fetch("Acme::Catalog::Book.available")).to be_query
    end

    it "lists the commands apart from the queries" do
      expect(register.commands.map { |entry| entry.fqn.to_s }).to contain_exactly(
        "Acme::Billing::Invoice.Issue", "Acme::Catalog::Book.Add"
      )
    end
  end

  it "refuses two discovered definitions of the same public address" do
    2.times { |number| write_domain("duplicate#{number}", "Catalog", "Book", "Add") }

    expect { described_class.load(@root) }
      .to raise_error(described_class::DuplicateFqn, /Acme::Catalog::Book.Add/)
  end

  it "pins every version and gives the world's latest version the unpinned address" do
    write_banking_versions
    register = described_class.load(@root)

    expect(register.entries.keys).to contain_exactly(
      "Acme::Banking::Account.Credit", "Acme::Banking@v1::Account.Credit", "Acme::Banking@v2::Account.Credit"
    )
  end

  private

  # One domain on disk: its bluebook and the world that names its realm.
  # @param options [Hash] `query:` and `version:` for the bluebook, `latest:` for the world
  def write_domain(name, domain, aggregate, command, **options)
    write_bluebook(name, bluebook_source(domain, aggregate, command, **options.slice(:query, :version)))
    write_world(name, domain, **options.slice(:latest))
  end

  def write_banking_versions
    %w[v1 v2].each do |version|
      latest = ("v2" if version == "v2")
      write_domain("banking_#{version}", "Banking", "Account", "Credit", version: version, latest: latest)
    end
  end

  def bluebook_source(domain, aggregate, command, query: nil, version: nil)
    <<~RUBY
      Hecks.bluebook #{domain.inspect}#{", version: #{version.inspect}" if version} do
        aggregate #{aggregate.inspect} do
          identified_by :id
          description "A #{aggregate.downcase}"
          command #{command.inspect} do
          end#{"\n    query #{query.inspect} do\n    end" if query}
        end
      end
    RUBY
  end

  def write_bluebook(name, source)
    directory = File.join(@root, name, "bluebook")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "#{name}.bluebook"), source)
  end

  def write_world(name, domain, realm: "Acme", latest: nil)
    directory = File.join(@root, name, "bluebook")
    lines = [
      "Hecks.world #{domain.inspect} do",
      "  realm #{realm.inspect}",
      ("  latest #{latest.inspect}" if latest),
      "end"
    ].compact
    File.write(File.join(directory, "#{name}.world"), "#{lines.join("\n")}\n")
  end
end

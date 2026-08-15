require "spec_helper"
require "tmpdir"

RSpec.describe Hecksagain::Bluebook::ProjectLoader do
  around do |example|
    @root = Dir.mktmpdir("hecksagain-project-loader-")
    example.run
  ensure
    FileUtils.remove_entry(@root) if @root
  end

  it "crawls Bluebook folders and registers commands and snake_case queries" do
    write_bluebook("catalog", <<~RUBY)
      Hecks.bluebook "Catalog" do
        aggregate "Book" do
          identified_by :id
          description "A book"
          command "Add" do
          end
          query "Available" do
          end
        end
      end
    RUBY
    write_world("catalog", "Catalog")
    write_bluebook("billing", <<~RUBY)
      Hecks.bluebook "Billing" do
        aggregate "Invoice" do
          identified_by :id
          description "An invoice"
          command "Issue" do
          end
        end
      end
    RUBY
    write_world("billing", "Billing")

    register = described_class.load(@root)

    expect(register.entries.keys).to contain_exactly(
      "Acme::Billing::Invoice.Issue",
      "Acme::Catalog::Book.Add",
      "Acme::Catalog::Book.available"
    )
    expect(register.fetch("Acme::Catalog::Book.available")).to be_query
    expect(register.commands.map { |entry| entry.fqn.to_s }).to contain_exactly(
      "Acme::Billing::Invoice.Issue", "Acme::Catalog::Book.Add"
    )
  end

  it "refuses two discovered definitions of the same public address" do
    2.times do |number|
      write_bluebook("duplicate#{number}", <<~RUBY)
        Hecks.bluebook "Catalog" do
          aggregate "Book" do
            identified_by :id
            description "A book"
            command "Add" do
            end
          end
        end
      RUBY
      write_world("duplicate#{number}", "Catalog")
    end

    expect { described_class.load(@root) }
      .to raise_error(described_class::DuplicateFqn, /Acme::Catalog::Book.Add/)
  end

  it "pins every version and gives the world's latest version the unpinned address" do
    %w[v1 v2].each do |version|
      write_bluebook("banking_#{version}", <<~RUBY)
        Hecks.bluebook "Banking", version: "#{version}" do
          aggregate "Account" do
            identified_by :id
            description "An account"
            command "Credit" do
            end
          end
        end
      RUBY
      write_world("banking_#{version}", "Banking", latest: (version == "v2" ? "v2" : nil))
    end

    register = described_class.load(@root)

    expect(register.entries.keys).to contain_exactly(
      "Acme::Banking::Account.Credit",
      "Acme::Banking@v1::Account.Credit",
      "Acme::Banking@v2::Account.Credit"
    )
  end

  private

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
    File.write(File.join(directory, "#{name}.world"), lines.join("\n") + "\n")
  end
end

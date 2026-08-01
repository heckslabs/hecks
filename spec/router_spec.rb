require "spec_helper"
require "tmpdir"

RSpec.describe Hecksagain::Router do
  around do |example|
    @root = Dir.mktmpdir("hecksagain-router-")
    example.run
  ensure
    FileUtils.remove_entry(@root) if @root
  end

  it "routes commands and queries for every discovered Bluebook through one door" do
    write_domain("catalog", "Catalog", <<~RUBY)
      aggregate "Book" do
        description "A book"
        attribute :code, Code
        value_object "Code" do
          attribute :value, String
        end
        identified_by { code.value }
        command "Add" do
          attribute :code, Code
        end
        query "Available" do
        end
      end
    RUBY
    write_domain("billing", "Billing", <<~RUBY)
      aggregate "Invoice" do
        description "An invoice"
        attribute :number, Number
        value_object "Number" do
          attribute :value, String
        end
        identified_by { number.value }
        command "Issue" do
          attribute :number, Number
        end
      end
    RUBY

    router = described_class.load(@root)

    expect(router.dispatch("Acme::Catalog::Book.Add", code: { value: "book-1" }).id).to eq("book-1")
    expect(router.query("Acme::Catalog::Book.available").map { |row| row.merge(code: row[:code].to_h) })
      .to eq([{ id: "book-1", code: { value: "book-1" } }])
    expect(router.dispatch("Acme::Billing::Invoice.Issue", number: { value: "invoice-1" }).id).to eq("invoice-1")
  end

  it "routes a domain read model without pretending it is an aggregate" do
    write_domain("banking", "Banking", <<~RUBY, realm: "Realm")
      read_model "CustomerPortfolio" do
        reference_to Customer
        include Customer
        include Account
      end
      aggregate "Customer" do
        identified_by { reference.value }
        attribute :reference, CustomerNumber
        attribute :name, PersonName
        value_object "CustomerNumber" do
          attribute :value, String
        end
        value_object "PersonName" do
          attribute :value, String
        end
        command "Register" do
          attribute :reference, CustomerNumber
          attribute :name, PersonName
        end
      end
      aggregate "Account" do
        identified_by { id.value }
        reference_to Customer
        attribute :number, AccountNumber
        attribute :balance, Balance, default: { cents: 0 }
        value_object "AccountNumber" do
          attribute :value, String
        end
        value_object "Balance" do
          attribute :cents, Integer
        end
        command "Open" do
          reference_to Customer
          attribute :number, AccountNumber
        end
      end
    RUBY

    described_class.boot(@root)
    Realm::Banking::Customer.Register(reference: { value: "C-1" }, name: { value: "Ada" })
    Realm::Banking::Account.Open(id: "A-1", customer_id: "C-1", number: { value: "ACC-1" })

    expect(Realm::Banking.customer_portfolio(customer: "C-1")).to eq([
      { customer: { id: "C-1", reference: { value: "C-1" }, name: { value: "Ada" } },
        accounts: [{ id: "A-1", customer_id: "C-1", number: { value: "ACC-1" }, balance: { cents: 0 } }] }
    ])
  ensure
    Object.send(:remove_const, :Realm) if Object.const_defined?(:Realm, false)
  end

  it "resolves an unpinned route to the world's latest domain version" do
    write_domain("banking_v1", "Banking", <<~RUBY, version: "v1")
      aggregate "Account" do
        identified_by { id.value }
        description "v1"
        command "Credit" do
        end
      end
    RUBY
    write_domain("banking_v2", "Banking", <<~RUBY, version: "v2", latest: "v2")
      aggregate "Account" do
        identified_by { id.value }
        description "v2"
        command "Credit" do
        end
      end
    RUBY

    router = described_class.load(@root)

    expect(router.resolve("Acme::Banking::Account.Credit").domain_version).to eq("v2")
    expect(router.resolve("Acme::Banking@v1::Account.Credit").domain_version).to eq("v1")
  end

  it "rejects an unknown route and mismatched command/query door" do
    write_domain("catalog", "Catalog", <<~RUBY)
      aggregate "Book" do
        identified_by { id.value }
        description "A book"
        command "Add" do; end
        query "Available" do; end
      end
    RUBY
    router = described_class.load(@root)

    expect { router.dispatch("Acme::Catalog::Book.available") }
      .to raise_error(described_class::WrongVerbKind, /query/)
    expect { router.query("Acme::Missing::Book.available") }
      .to raise_error(described_class::UnknownAddress, /no Bluebook route/)
  end

  it "installs latest command and query aliases as Ruby namespace calls" do
    write_domain("catalog", "Catalog", <<~RUBY, realm: "SugarRealm")
      aggregate "Book" do
        description "A book"
        attribute :code, Code
        value_object "Code" do
          attribute :value, String
        end
        identified_by { code.value }
        command "Add" do
          attribute :code, Code
        end
        query "Available" do
        end
      end
    RUBY

    described_class.boot(@root)

    expect(SugarRealm::Catalog::Book.Add(code: { value: "book-1" }).id).to eq("book-1")
    expect(SugarRealm::Catalog::Book.available.map { |row| row.merge(code: row[:code].to_h) })
      .to eq([{ id: "book-1", code: { value: "book-1" } }])
  ensure
    Object.send(:remove_const, :SugarRealm) if Object.const_defined?(:SugarRealm, false)
  end

  it "keeps version selection in an aggregate options pipe, separate from payload fields" do
    write_domain("banking_v1", "Banking", <<~RUBY, version: "v1", realm: "OptionsRealm")
      aggregate "Account" do
        description "An account"
        attribute :code, Code
        value_object "Code" do
          attribute :value, String
        end
        identified_by { code.value }
        command "LegacyOpen" do
          attribute :code, Code
        end
      end
    RUBY
    write_domain("banking_v2", "Banking", <<~RUBY, version: "v2", latest: "v2", realm: "OptionsRealm")
      aggregate "Account" do
        description "An account"
        attribute :code, Code
        value_object "Code" do
          attribute :value, String
        end
        identified_by { code.value }
        command "Open" do
          attribute :code, Code
        end
      end
    RUBY

    described_class.boot(@root)

    expect(OptionsRealm::Banking::Account.Open(code: { value: "latest" }).id).to eq("latest")
    expect(OptionsRealm::Banking::Account.options(version: :v1).LegacyOpen(code: { value: "legacy" }).id).to eq("legacy")
  ensure
    Object.send(:remove_const, :OptionsRealm) if Object.const_defined?(:OptionsRealm, false)
  end

  it "rejects unknown namespace options and non-command method names" do
    write_domain("catalog", "Catalog", <<~RUBY, realm: "EdgeRealm")
      aggregate "Book" do
        identified_by { id.value }
        description "A book"
        command "Add" do
        end
      end
    RUBY
    described_class.boot(@root)

    expect { EdgeRealm::Catalog::Book.options(region: :us) }
      .to raise_error(ArgumentError, /unknown router options/)
    expect { EdgeRealm::Catalog::Book.public_send("not-a-route") }
      .to raise_error(NoMethodError)
  ensure
    Object.send(:remove_const, :EdgeRealm) if Object.const_defined?(:EdgeRealm, false)
  end

  it "installs Aggregate.Command when one latest route owns that short name" do
    write_domain("catalog", "Catalog", <<~RUBY, realm: "ShortcutRealm")
      aggregate "ShortcutBook" do
        description "A book"
        attribute :code, Code
        value_object "Code" do
          attribute :value, String
        end
        identified_by { code.value }
        command "Add" do
          attribute :code, Code
        end
      end
    RUBY

    described_class.boot(@root)

    expect(ShortcutBook.Add(code: { value: "book-1" }).id).to eq("book-1")
  ensure
    Object.send(:remove_const, :ShortcutBook) if Object.const_defined?(:ShortcutBook, false)
    Object.send(:remove_const, :ShortcutRealm) if Object.const_defined?(:ShortcutRealm, false)
  end

  it "refuses an ambiguous Aggregate.Command and names every candidate" do
    %w[catalog billing].each do |domain_name|
      write_domain(domain_name, domain_name.capitalize, <<~RUBY, realm: "AmbiguityRealm")
        aggregate "SharedShortcutBook" do
          identified_by { id.value }
          description "A book"
          command "Add" do
          end
        end
      RUBY
    end

    described_class.boot(@root)

    expect { SharedShortcutBook.Add }
      .to raise_error(described_class::AmbiguousShortRoute,
                      /AmbiguityRealm::Billing::SharedShortcutBook.Add.*AmbiguityRealm::Catalog::SharedShortcutBook.Add/)
  ensure
    Object.send(:remove_const, :SharedShortcutBook) if Object.const_defined?(:SharedShortcutBook, false)
    Object.send(:remove_const, :AmbiguityRealm) if Object.const_defined?(:AmbiguityRealm, false)
  end

  private

  def write_domain(directory_name, domain, body, version: nil, latest: nil, realm: "Acme")
    directory = File.join(@root, directory_name, "bluebook")
    FileUtils.mkdir_p(directory)
    version_clause = version ? ", version: #{version.inspect}" : ""
    File.write(File.join(directory, "#{directory_name}.bluebook"), "Hecks.bluebook #{domain.inspect}#{version_clause} do\n#{body}\nend\n")
    world = ["Hecks.world #{domain.inspect} do", "  realm #{realm.inspect}", ("  latest #{latest.inspect}" if latest), "end"].compact
    File.write(File.join(directory, "#{directory_name}.world"), world.join("\n") + "\n")
  end
end

require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::Router do
  ROUTER_INVOICE_BLUEBOOK = <<~RUBY.freeze
    aggregate "Invoice" do
      description "An invoice"
      attribute :number, Number
      value_object "Number" do
        attribute :value, String
      end
      identified_by :number
      command "Issue" do
        attribute :number, Number
      end
    end
  RUBY

  ROUTER_BANKING_BLUEBOOK = <<~RUBY.freeze
    read_model "CustomerPortfolio" do
      reference_to Customer
      include Customer
      include Account
    end
    aggregate "Customer" do
      identified_by :reference
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
      identified_by :id
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

  ROUTER_PORTFOLIO = [
    { customer: { id: "C-1", reference: { value: "C-1" }, name: { value: "Ada" } },
      accounts: [{ id: "A-1", customer: "C-1", number: { value: "ACC-1" }, balance: { cents: 0 } }] }
  ].freeze

  ROUTER_BOOK_BLUEBOOK = <<~RUBY.freeze
    aggregate "Book" do
      identified_by :code
      attribute :code, Code
      value_object "Code" do
        attribute :value, String
      end
      command "Add" do
        attribute :code, Code
      end
    end
  RUBY

  # An account with one command, named by the `command` placeholder, for two versions of a domain.
  ROUTER_ACCOUNT_BLUEBOOK = <<~RUBY.freeze
    aggregate "Account" do
      description "An account"
      attribute :code, Code
      value_object "Code" do
        attribute :value, String
      end
      identified_by :code
      command "%<command>s" do
        attribute :code, Code
      end
    end
  RUBY

  ROUTER_QUERYABLE_BLUEBOOK = <<~RUBY.freeze
    aggregate "Book" do
      identified_by :id
      description "A book"
      command "Add" do; end
      query "Available" do; end
    end
  RUBY

  ROUTER_EDGE_BLUEBOOK = <<~RUBY.freeze
    aggregate "Book" do
      identified_by :id
      description "A book"
      command "Add" do
      end
    end
  RUBY

  ROUTER_SHORTCUT_BLUEBOOK = <<~RUBY.freeze
    aggregate "ShortcutBook" do
      description "A book"
      attribute :code, Code
      value_object "Code" do
        attribute :value, String
      end
      identified_by :code
      command "Add" do
        attribute :code, Code
      end
    end
  RUBY

  ROUTER_SHARED_BLUEBOOK = <<~RUBY.freeze
    aggregate "SharedShortcutBook" do
      identified_by :id
      description "A book"
      command "Add" do
      end
    end
  RUBY

  ROUTER_AMBIGUOUS_ROUTE = /AmbiguityRealm::Billing::SharedShortcutBook.Add.*AmbiguityRealm::Catalog::SharedShortcutBook.Add/

  around do |example|
    @root = Dir.mktmpdir("hecks-router-")
    example.run
  ensure
    FileUtils.remove_entry(@root) if @root
  end

  context "with a catalog and a billing domain discovered under one root" do
    let(:router) { described_class.load(@root) }

    before do
      write_domain("catalog", "Catalog", catalog_book_with_query_bluebook)
      write_domain("billing", "Billing", ROUTER_INVOICE_BLUEBOOK)
    end

    it "routes commands for every discovered Bluebook through one door", :aggregate_failures do
      expect(router.dispatch("Acme::Catalog::Book.Add", code: { value: "book-1" }).id).to eq("book-1")
      expect(router.dispatch("Acme::Billing::Invoice.Issue", number: { value: "invoice-1" }).id).to eq("invoice-1")
    end

    it "routes queries for every discovered Bluebook through one door" do
      router.dispatch("Acme::Catalog::Book.Add", code: { value: "book-1" })
      expect(router.query("Acme::Catalog::Book.available").map { |row| row.merge(code: row[:code].to_h) })
        .to eq([{ id: "book-1", code: { value: "book-1" } }])
    end
  end

  # Needs two aggregates and a read model over both, dispatched live, to show it aggregates state.
  it "routes a domain read model without pretending it is an aggregate" do
    write_domain("banking", "Banking", ROUTER_BANKING_BLUEBOOK, realm: "Realm")
    described_class.boot(@root)
    Realm::Banking::Customer.Register(reference: { value: "C-1" }, name: { value: "Ada" })
    Realm::Banking::Account.Open(id: "A-1", customer: "C-1", number: { value: "ACC-1" })

    expect(Realm::Banking.customer_portfolio(customer: "C-1")).to eq(ROUTER_PORTFOLIO)
  end

  # `install_namespace_entry` installs only declared verbs, so an aggregate with no
  # lookup-by-id query of its own needs `.find`/`.all`/`.count` from the router too.
  context "with an aggregate that declares no lookup of its own" do
    before do
      write_domain("catalog", "Catalog", ROUTER_BOOK_BLUEBOOK, realm: "Realm")
      described_class.boot(@root)
      Realm::Catalog::Book.Add(code: { value: "B-1" })
    end

    it "gives the router surface .find, not just its own declared verbs", :aggregate_failures do
      found = Realm::Catalog::Book.find("B-1")

      expect(found.id).to eq("B-1")
      expect(found.code.value).to eq("B-1")
      expect(Realm::Catalog::Book.find("nope")).to be_nil
    end

    it "gives the router surface .all and .count too", :aggregate_failures do
      expect(Realm::Catalog::Book.all.map(&:id)).to eq(["B-1"])
      expect(Realm::Catalog::Book.count).to eq(1)
    end
  end

  it "resolves an unpinned route to the world's latest domain version", :aggregate_failures do
    write_domain("banking_v1", "Banking", account_bluebook("v1"), version: "v1")
    write_domain("banking_v2", "Banking", account_bluebook("v2"), version: "v2", latest: "v2")
    router = described_class.load(@root)

    expect(router.resolve("Acme::Banking::Account.Credit").domain_version).to eq("v2")
    expect(router.resolve("Acme::Banking@v1::Account.Credit").domain_version).to eq("v1")
  end

  it "rejects a command/query door that does not match the route" do
    router = load_router("catalog", "Catalog", ROUTER_QUERYABLE_BLUEBOOK)

    expect { router.dispatch("Acme::Catalog::Book.available") }.to raise_error(described_class::WrongVerbKind, /query/)
  end

  it "rejects an unknown route" do
    router = load_router("catalog", "Catalog", ROUTER_QUERYABLE_BLUEBOOK)

    expect { router.query("Acme::Missing::Book.available") }
      .to raise_error(described_class::UnknownAddress, /no Bluebook route/)
  end

  it "installs latest command and query aliases as Ruby namespace calls", :aggregate_failures do
    write_domain("catalog", "Catalog", catalog_book_with_query_bluebook, realm: "SugarRealm")
    described_class.boot(@root)

    expect(SugarRealm::Catalog::Book.Add(code: { value: "book-1" }).id).to eq("book-1")
    expect(SugarRealm::Catalog::Book.available.map { |row| row.merge(code: row[:code].to_h) })
      .to eq([{ id: "book-1", code: { value: "book-1" } }])
  end

  # Default resolves to latest and options(version:) pins the other, on one two-version domain.
  it "keeps version selection in an aggregate options pipe, separate from payload fields", :aggregate_failures do
    write_option_versions
    described_class.boot(@root)

    expect(OptionsRealm::Banking::Account.Open(code: { value: "latest" }).id).to eq("latest")
    expect(OptionsRealm::Banking::Account.options(version: :v1).LegacyOpen(code: { value: "legacy" }).id).to eq("legacy")
  end

  it "rejects unknown namespace options and non-command method names", :aggregate_failures do
    write_domain("catalog", "Catalog", ROUTER_EDGE_BLUEBOOK, realm: "EdgeRealm")
    described_class.boot(@root)

    expect { EdgeRealm::Catalog::Book.options(region: :us) }.to raise_error(ArgumentError, /unknown router options/)
    expect { EdgeRealm::Catalog::Book.public_send("not-a-route") }.to raise_error(NoMethodError)
  end

  it "installs Aggregate.Command when one latest route owns that short name" do
    write_domain("catalog", "Catalog", ROUTER_SHORTCUT_BLUEBOOK, realm: "ShortcutRealm")
    stub_const("ShortcutBook", Module.new)
    described_class.boot(@root)

    expect(ShortcutBook.Add(code: { value: "book-1" }).id).to eq("book-1")
  end

  it "refuses an ambiguous Aggregate.Command and names every candidate" do
    %w[catalog billing].each { |name| write_domain(name, name.capitalize, ROUTER_SHARED_BLUEBOOK, realm: "AmbiguityRealm") }
    stub_const("SharedShortcutBook", Module.new)
    described_class.boot(@root)

    expect { SharedShortcutBook.Add }.to raise_error(described_class::AmbiguousShortRoute, ROUTER_AMBIGUOUS_ROUTE)
  end

  private

  # Book aggregate with a query as well as a command, shared by two examples.
  def catalog_book_with_query_bluebook
    <<~RUBY
      aggregate "Book" do
        description "A book"
        attribute :code, Code
        value_object "Code" do
          attribute :value, String
        end
        identified_by :code
        command "Add" do
          attribute :code, Code
        end
        query "Available" do
        end
      end
    RUBY
  end

  # An account aggregate whose description names the domain version it belongs to.
  def account_bluebook(description)
    <<~RUBY
      aggregate "Account" do
        identified_by :id
        description #{description.inspect}
        command "Credit" do
        end
      end
    RUBY
  end

  def write_option_versions
    write_domain("banking_v1", "Banking", format(ROUTER_ACCOUNT_BLUEBOOK, command: "LegacyOpen"),
                 version: "v1", realm: "OptionsRealm")
    write_domain("banking_v2", "Banking", format(ROUTER_ACCOUNT_BLUEBOOK, command: "Open"),
                 version: "v2", latest: "v2", realm: "OptionsRealm")
  end

  def load_router(directory_name, domain, body)
    write_domain(directory_name, domain, body)
    described_class.load(@root)
  end

  # Writes a one-domain bluebook and its world under the root. The options are `version:`,
  # `latest:` and `realm:`; a realm other than the default is reserved as a top-level module that
  # the router installs into and the example then drops.
  def write_domain(directory_name, domain, body, **options)
    directory = File.join(@root, directory_name, "bluebook")
    FileUtils.mkdir_p(directory)
    reserve_realm(options[:realm])
    version_clause = options[:version] ? ", version: #{options[:version].inspect}" : ""
    File.write(File.join(directory, "#{directory_name}.bluebook"),
               "Hecks.bluebook #{domain.inspect}#{version_clause} do\n#{body}\nend\n")
    File.write(File.join(directory, "#{directory_name}.world"), world_source(domain, options))
  end

  def reserve_realm(realm)
    stub_const(realm, Module.new) if realm && !Object.const_defined?(realm, false)
  end

  def world_source(domain, options)
    lines = ["Hecks.world #{domain.inspect} do", "  realm #{options.fetch(:realm, "Acme").inspect}",
             ("  latest #{options[:latest].inspect}" if options[:latest]), "end"].compact
    "#{lines.join("\n")}\n"
  end
end

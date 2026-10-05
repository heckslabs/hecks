require "spec_helper"
require "tmpdir"
require_relative "../../support/crew_domain"
require_relative "../../../lib/hecks/hecks/adapters/first_admin"

# The first administrator of a domain that provides "membership": admitted and granted as a caller
# naming the role the grant is gated to, once, and never when an administrator exists.
RSpec.describe Hecks::Adapters::FirstAdmin do
  let(:dir) { Dir.mktmpdir("hecks-first-admin") }
  let(:runtime) { Hecks.boot(CrewDomain.write(dir), install_doors: false) }
  let(:bootstrap) { described_class.new(runtime) }

  after { FileUtils.remove_entry(dir) }

  def people = runtime.query("Crew::Person.All").map { |row| Hecks::Doors::JsonDoor.materialize(row) }

  it "admits the person and grants the role the grant is gated to" do
    result = bootstrap.call(email: "ada@example.com", name: "Ada")

    expect(result.to_s).to eq("Granted Admin access to ada@example.com (admitted first)")
    expect(people).to contain_exactly(include(email: { value: "ada@example.com" }, name: { value: "Ada" },
                                              role: { value: "Admin" }))
  end

  it "names the person by the start of their email when no name is given" do
    bootstrap.call(email: "ada@example.com")

    expect(people.first.fetch(:name)).to eq(value: "ada")
  end

  it "grants a person who was admitted already without admitting them again" do
    Hecks.as_caller(role: "Admin") do
      runtime.dispatch("Crew::Person.Admit", with: { email: { value: "ada@example.com" }, name: { value: "Ada L" } })
    end

    result = bootstrap.call(email: "ada@example.com", name: "Ignored")

    expect(result.admitted).to be(false)
    expect(people).to contain_exactly(include(name: { value: "Ada L" }, role: { value: "Admin" }))
  end

  it "grants the role it is asked for" do
    expect(bootstrap.call(email: "ada@example.com", role: "Owner").role).to eq("Owner")
    expect(people.first.fetch(:role)).to eq(value: "Owner")
  end

  it "refuses once an administrator exists, naming them, and changes nothing" do
    bootstrap.call(email: "ada@example.com")

    expect { bootstrap.call(email: "grace@example.com") }
      .to raise_error(Hecks::Runtime::NotFound, /an administrator already exists \(ada@example.com\)/)
    expect(people.map { |person| person.dig(:email, :value) }).to eq(["ada@example.com"])
  end

  it "counts an Owner as an administrator too" do
    bootstrap.call(email: "ada@example.com", role: "Owner")

    expect { bootstrap.call(email: "grace@example.com") }
      .to raise_error(Hecks::Runtime::NotFound, /an administrator already exists/)
  end

  it "does not count a person who holds another role" do
    bootstrap.call(email: "ada@example.com", role: "Editor")

    expect(bootstrap.call(email: "grace@example.com").role).to eq("Admin")
  end

  it "refuses something that is not an email" do
    expect { bootstrap.call(email: "ada") }.to raise_error(Hecks::Runtime::NotFound, /not an email address/)
  end

  it "refuses a domain that provides no membership" do
    CrewDomain.write(dir)
    File.write(File.join(dir, "crew.bluebook"), CrewDomain::BLUEBOOK.sub(/^\s*provides "membership".*\n/, ""))
    bare = described_class.new(Hecks.boot(dir, install_doors: false))

    expect { bare.call(email: "ada@example.com") }
      .to raise_error(Hecks::Runtime::NotFound, /provides "membership"/)
  end
end

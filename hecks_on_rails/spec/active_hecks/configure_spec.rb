# Specs for Hecks.configure with Rails defined
#
# Verifies the configure block returns a Configuration, does not auto-boot
# when Rails is present, and that calling boot! activates DomainModelCompat.
#
require "spec_helper"
require "rails_spec_helper"

RSpec.describe "Hecks.configure (Rails context)" do
  after { Hecks.instance_variable_set(:@configuration, nil) }

  it "returns a Configuration object" do
    config = Hecks.configure { }
    expect(config).to be_a(Hecks::Configuration)
  end

  it "does not call boot! automatically when Rails is defined" do
    config = Hecks.configure { }
    # boot! would populate @apps; without it, apps is empty
    expect(config.apps).to be_empty
  end

  it "adapter :memory is the default" do
    config = Hecks.configure { }
    expect(config.instance_variable_get(:@adapter_type)).to eq(:memory)
  end

  it "domain method registers domain entries" do
    config = Hecks.configure { domain "fake_gem" }
    domains = config.instance_variable_get(:@domains)
    expect(domains.map { |d| d[:gem_name] }).to include("fake_gem")
  end

  it "calling boot! activates DomainModelCompat on aggregate classes" do
    domain = Hecks.domain "ConfigureSpecPizzas" do
      aggregate "CSPizza" do
        attribute :name, String
        command "CreateCSPizza" do
          attribute :name, String
        end
      end
    end

    Hecks.load(domain, force: true)
    mod = Object.const_get("ConfigureSpecPizzasDomain")

    ActiveHecks.activate(mod, domain: domain)

    expect(ConfigureSpecPizzasDomain::CSPizza.ancestors).to include(ActiveHecks::DomainModelCompat)
  end
end

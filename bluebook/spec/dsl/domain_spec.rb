require "spec_helper"

# Specs for the version: kwarg added to Hecks.domain (HEC-456).
#
# Covers:
#   - version stored on the domain IR
#   - nil version is valid (version is optional)
#   - semver accepted
#   - CalVer accepted
#   - invalid version raises Hecks::InvalidDomainVersion
#   - version appears in generated gemspec VERSION constant

RSpec.describe "Hecks.domain version: kwarg" do
  def minimal_domain(version: nil)
    Hecks.domain("Banking", version: version) do
      aggregate("Account") do
        attribute :name, String
        command("CreateAccount") { attribute :name, String }
      end
    end
  end

  describe "IR storage" do
    it "stores a semver version on the domain IR" do
      domain = minimal_domain(version: "2.1.0")
      expect(domain.version).to eq("2.1.0")
    end

    it "stores a CalVer version on the domain IR" do
      domain = minimal_domain(version: "2026.04.01.1")
      expect(domain.version).to eq("2026.04.01.1")
    end

    it "stores nil when version is omitted" do
      domain = minimal_domain
      expect(domain.version).to be_nil
    end
  end

  describe "validation" do
    it "raises InvalidDomainVersion for an invalid version string" do
      expect {
        minimal_domain(version: "not-a-version")
      }.to raise_error(Hecks::InvalidDomainVersion)
    end

    it "raises InvalidDomainVersion for a two-part version" do
      expect {
        minimal_domain(version: "1.0")
      }.to raise_error(Hecks::InvalidDomainVersion)
    end

    it "does not raise when version is nil" do
      expect { minimal_domain(version: nil) }.not_to raise_error
    end
  end

  describe "generated gemspec" do
    it "uses domain.version in the gemspec when set" do
      domain = minimal_domain(version: "3.0.1")
      gen = Hecks::Generators::Infrastructure::DomainGemGenerator.new(domain, output_dir: Dir.mktmpdir)
      root = gen.generate
      gemspec = File.read(File.join(root, "#{domain.gem_name}.gemspec"))
      expect(gemspec).to include("3.0.1")
    end

    it "falls back to the generator version when domain.version is nil" do
      domain = minimal_domain
      gen = Hecks::Generators::Infrastructure::DomainGemGenerator.new(domain, version: "0.9.0", output_dir: Dir.mktmpdir)
      root = gen.generate
      gemspec = File.read(File.join(root, "#{domain.gem_name}.gemspec"))
      expect(gemspec).to include("0.9.0")
    end
  end
end

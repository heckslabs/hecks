require "spec_helper"
require "tmpdir"

# A field a deployment marks sensitive (`has_phi(readable_by:)` in a
# `.hecksagon`) is tagged in the glossary with its category and listed under
# its aggregate. The marking arrives as `options[:markings]`; without it the
# glossary says nothing about sensitivity, so every committed glossary is
# untouched.
RSpec.describe "glossary sensitivity tagging" do
  BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Clinic" do
      vision "Patients and their care."
      core

      aggregate "Patient" do
        description "One person under care."
        identified_by :patient_id

        value_object "PatientId" do
          attribute :value, String
          invariant("a patient is identified") { !value.to_s.empty? }
        end

        value_object "Contact" do
          attribute :phone,     String
          attribute :allergies, String
        end

        attribute :patient_id, PatientId
        attribute :contact,    Contact

        command "Admit" do
          role "Nurse"
          goal "Take a patient into care"
          attribute :patient_id, PatientId
          attribute :contact,    Contact
          emits "PatientAdmitted"
        end
      end
    end
  RUBY

  ALLERGIES = { domain: "Clinic::Patient", attribute_path: "contact.allergies",
                category: "phi", readable_by: "Privacy officer" }.freeze

  def load_clinic(dir)
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
     InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
    InMemoryDomain.load_bluebook_files(dir)
  end

  def chapter
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "clinic.bluebook"), BLUEBOOK)
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { load_clinic(dir) }
      registry.bluebook("Clinic")
    end
  end

  def glossary(markings = nil)
    options = markings ? { markings: markings } : {}
    Hecks::Projector.call(:glossary, bluebook: chapter, options: options)
  end

  it "tags the marked field beside its type, and only that field" do
    markdown = glossary([ALLERGIES])["glossary.md"]
    expect(markdown).to include("Made up of phone (text) and allergies (text, PHI).")
  end

  it "lists every marking under its aggregate, with who may read it" do
    markdown = glossary([ALLERGIES])["glossary.md"]
    expect(markdown).to include("**Handled as sensitive**\n\n" \
                                "- Contact allergies: PHI, read unredacted only by the privacy officer.")
  end

  it "carries the tag into the page" do
    html = glossary([ALLERGIES])["html/index.html"]
    expect(html).to include("Handled as sensitive", "allergies (text, PHI)")
  end

  it "says nothing about sensitivity when no marking is handed in", :aggregate_failures do
    expect(glossary["glossary.md"]).not_to match(/PHI|sensitive/)
    expect(glossary([])).to eq(glossary)
  end

  it "ignores a marking that names another domain's aggregate" do
    other = ALLERGIES.merge(domain: "Elsewhere::Patient")
    expect(glossary([other])).to eq(glossary)
  end

  it "still lists a marking whose path reaches no declared field", :aggregate_failures do
    stray = ALLERGIES.merge(attribute_path: "contact.blood_type")
    markdown = glossary([stray])["glossary.md"]
    expect(markdown).to include("- Contact blood type: PHI,")
    expect(markdown).not_to include("(text, PHI)")
  end
end

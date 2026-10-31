require "spec_helper"

# The QualityControl fields a stored record may leave empty: a sweep, bug, target, angle or
# improvement that was never given the text. Each stays a String value object, and is optional so
# the c4f690 shape's audit does not refuse a record that holds null there.
RSpec.describe "the QualityControl bluebook's optional fields" do
  def optional_fields
    {
      "Sweep"       => %w[notes],
      "Bug"         => %w[reason next_step cause site verification commit],
      "Target"      => %w[reason],
      "Angle"       => %w[resolution reason],
      "Improvement" => %w[commit]
    }
  end

  def bluebook
    @bluebook ||= Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/quality_control"), install_driving: false)
                       .registry.bluebook("QualityControl")
  end

  def attribute_of(aggregate, field)
    bluebook.aggregate(aggregate).attributes.find { |attribute| attribute.name.to_s == field }
  end

  it "makes each of the eleven fields optional", :aggregate_failures do
    optional_fields.each do |aggregate, fields|
      fields.each do |field|
        expect(attribute_of(aggregate, field)&.optional?).to be(true), "#{aggregate}.#{field} is not optional"
      end
    end
  end

  it "keeps the fields' types as String value objects", :aggregate_failures do
    optional_fields.each do |aggregate, fields|
      fields.each do |field|
        expect(attribute_of(aggregate, field)&.type.to_s).to match(/\A[A-Z]/), "#{aggregate}.#{field} lost its type"
      end
    end
  end
end

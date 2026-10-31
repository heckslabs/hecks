require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/no_id_string_attribute"

RSpec.describe RuboCop::Cop::Hecks::NoIdStringAttribute do
  include_context "with a Hecks cop under test"

  it "flags an aggregate attribute that stores another record's id as a string" do
    expect_offense(<<~RUBY)
      aggregate "Section" do
        attribute :teacher_id, String
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `teacher_id` stores another record's id as a string. Declare `reference_to Teacher, as: :teacher` so the domain holds the reference, and let the adapter map the school's ids.
      end
    RUBY
  end

  it "does not flag a query argument" do
    expect_no_offenses(<<~RUBY)
      query "ByAuthor" do
        attribute :author_id, String
        where author: :author_id
      end
    RUBY
  end

  it "does not flag a reference" do
    expect_no_offenses("reference_to Person, as: :teacher")
  end

  it "does not flag an attribute that is not an id" do
    expect_no_offenses("attribute :name, String")
  end
end

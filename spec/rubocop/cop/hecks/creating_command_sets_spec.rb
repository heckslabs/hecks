require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/creating_command_sets"

RSpec.describe RuboCop::Cop::Hecks::CreatingCommandSets do
  include_context "with a Hecks cop under test"

  it "flags an attribute of a creating command that no sets copies onto the aggregate" do
    expect_offense(<<~RUBY)
      aggregate "Sticker" do
        command "Print" do
          attribute :ref, StickerRef
          ^^^^^^^^^^^^^^^^^^^^^^^^^^ Command `Print` creates its aggregate, so its attribute `ref` must be set onto it. Add `sets :ref`.
        end
      end
    RUBY
  end

  it "does not flag a creating command whose attribute is set" do
    expect_no_offenses(<<~RUBY)
      aggregate "Sticker" do
        command "Print" do
          attribute :ref, StickerRef
          sets :ref
        end
      end
    RUBY
  end

  it "does not flag a command that references its own aggregate" do
    expect_no_offenses(<<~RUBY)
      aggregate "Sticker" do
        command "Reprice" do
          reference_to Sticker
          attribute :price, Price
        end
      end
    RUBY
  end
end

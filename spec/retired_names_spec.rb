require "spec_helper"

# ADR 0134 renames Ruby names that clients may use. Each old name still answers with the new one's
# behavior, and says on standard error which name replaces it.
RSpec.describe Hecks::RetiredNames do
  it "answers Hecks::Bluebook::Chapter with Hecks::Bluebook::Declaration", :aggregate_failures do
    found = nil

    expect { found = Hecks::Bluebook::Chapter }
      .to output(/Hecks::Bluebook::Chapter is deprecated, use Hecks::Bluebook::Declaration/).to_stderr
    expect(found).to equal(Hecks::Bluebook::Declaration)
  end

  it "answers Hecks::Chapters with Hecks::FrameworkBluebooks", :aggregate_failures do
    found = nil

    expect { found = Hecks::Chapters }
      .to output(/Hecks::Chapters is deprecated, use Hecks::FrameworkBluebooks/).to_stderr
    expect(found).to equal(Hecks::FrameworkBluebooks)
  end

  it "answers Registry#forget_chapter as forget_bluebook does", :aggregate_failures do
    registry = Hecks::Runtime::Registry.new
    allow(registry).to receive(:forget_bluebook)

    expect { registry.forget_chapter("Pizzas") }
      .to output(/Registry#forget_chapter is deprecated, use #forget_bluebook/).to_stderr
    expect(registry).to have_received(:forget_bluebook).with("Pizzas")
  end

  it "says nothing for the new names and still refuses a constant that never existed", :aggregate_failures do
    expect { Hecks::Bluebook::Declaration && Hecks::FrameworkBluebooks }.not_to output.to_stderr
    expect { Hecks::Bluebook::NeverDeclared }.to raise_error(NameError)
  end
end

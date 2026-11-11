require "spec_helper"
require "json"
require "hecks/hecks/adapters/main_integration/train"

# What a boarding does to the push train's copy before it asks the train to push: the copy is
# brought to the boarded commit itself, never to origin/main. The runner stands in for git and for
# the train, so nothing is checked out or boarded.
RSpec.describe Hecks::Adapters::MainIntegration::Train, "#refresh" do
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:landed) { "b" * 40 }
  let(:older) { "a" * 40 }

  # A fake git: `head` is where the copy stands, `dirty` whether it has tracked changes, and
  # `checkout` what a detached checkout answers. A successful checkout moves `head` to the commit.
  def copy(head: older, dirty: false, checkout: [true, ""])
    @calls = []
    @head = head
    runner = lambda do |argv, **|
      @calls << argv
      answer(argv, dirty, checkout)
    end
    described_class.new(runner, root: "/train")
  end

  def answer(argv, dirty, checkout)
    case argv[1]
    when "rev-parse" then [true, "#{argv.last == "HEAD" ? @head : landed}\n"]
    when "status" then [true, dirty ? " M x.bluebook\n" : ""]
    else
      @head = landed if checkout.first
      checkout
    end
  end

  def checkouts = @calls.select { |argv| argv[1] == "checkout" }

  it "checks out the landed commit and says where the copy was and is" do
    expect(copy.refresh(landed)).to eq("refreshed the train from #{older[0, 10]} to #{landed[0, 10]}")
  end

  it "checks out the commit itself, detached, not origin/main", :aggregate_failures do
    copy.refresh(landed)
    expect(checkouts).to eq([["git", "checkout", "-q", "--detach", landed]])
  end

  it "leaves a clean copy already at the commit alone", :aggregate_failures do
    expect(copy(head: landed).refresh(landed)).to eq("train copy already at #{landed[0, 10]}")
    expect(checkouts).to be_empty
  end

  it "leaves a dirty copy already at the commit alone" do
    expect(copy(head: landed, dirty: true).refresh(landed)).to start_with("train copy already")
  end

  it "refuses by name a dirty copy at an older commit" do
    expect { copy(dirty: true).refresh(landed) }.to raise_error(failure, /refreshed to bbbbbbbbbb: .*tracked changes/)
  end

  it "refuses by name a checkout that fails, with git's reason" do
    stuck = copy(checkout: [false, "fatal: reference is not a tree\n"])
    expect { stuck.refresh(landed) }.to raise_error(failure, /refreshed to bbbbbbbbbb: fatal: reference is not a tree/)
  end

  it "refuses a copy that does not hold the commit" do
    expect { described_class.new(->(*, **) { [true, ""] }, root: "/train").refresh(landed) }
      .to raise_error(failure, /not in the train copy/)
  end
end

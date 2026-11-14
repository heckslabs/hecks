require "spec_helper"
require "tmpdir"
require_relative "support/roll_forward_fixtures"

# A roll heard by a worktree's process fills for the main checkout, so no work item is started in
# another work item's worktree.
module RollCheckoutFixtures
  def git(dir, *) = system("git", "-C", dir, *, out: File::NULL, err: File::NULL, exception: true)

  # A repository with one commit and a linked worktree of another item, as [main, worktree].
  def repository_with_worktree(dir)
    main = File.realpath(dir)
    git(main, "init", "-q", "-b", "main")
    git(main, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
    git(main, "worktree", "add", "-q", "-b", "other-item", File.join(main, "other-item"))
    [main, File.join(main, "other-item")]
  end
end

RSpec.describe "a roll heard in a worktree" do
  include RollForwardFixtures
  include RollCheckoutFixtures

  let(:checkout) { Hecks::Adapters::Dispatching::Checkout }

  around do |example|
    Dir.mktmpdir do |dir|
      @main, @tree = repository_with_worktree(dir)
      example.run
    end
  end

  before { Hecks::Adapters::Dispatching::LastRoll.reset! }

  it "names the main checkout from a linked worktree and from the main checkout", :aggregate_failures do
    expect(checkout.main(@tree)).to eq(@main)
    expect(checkout.main(@main)).to eq(@main)
  end

  it "names the directory itself outside a repository" do
    Dir.mktmpdir { |plain| expect(checkout.main(File.realpath(plain))).to eq(File.realpath(plain)) }
  end

  it "fills with the main checkout as the repo, not the worktree it runs in" do
    allow(Hecks::Adapters::Dispatching::Launcher).to receive(:new).and_call_original
    allow(Dir).to receive(:pwd).and_return(@tree)
    rolling({}).roll

    expect(Hecks::Adapters::Dispatching::Launcher).to have_received(:new).with(@main, anything).at_least(:once)
  end
end

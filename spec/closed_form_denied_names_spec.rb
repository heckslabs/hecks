require "spec_helper"

# A `.hecksagon` bind verb and a `.world` binding verb are open words that Ruby reaches through
# `method_missing`, so the closed form refuses any that Ruby would find first
# (rust/parser/src/closed/denied.rs, `RUBY_METHODS`). This holds that list to the running Ruby with
# the gem loaded, so a method that a new Ruby or a loaded gem adds to every object fails here.
RSpec.describe "the closed form's list of Ruby methods" do
  def listed
    source = File.read(File.join(InMemoryDomain::ROOT, "rust/parser/src/closed/denied.rs"))
    source[/pub const RUBY_METHODS: &\[&str\] = &\[(.*?)\];/m, 1].scan(/"([^"]+)"/).flatten
  end

  def answered_by_every_object
    [Object, BasicObject, Kernel].flat_map do |owner|
      owner.public_instance_methods + owner.protected_instance_methods + owner.private_instance_methods
    end.map(&:to_s).uniq
  end

  it "names every method every object answers, so no open word reaches one" do
    expect(answered_by_every_object - listed).to be_empty
  end

  it "keeps the list sorted and free of repeats, as the Rust side's own test does" do
    expect(listed).to eq(listed.uniq.sort)
  end
end

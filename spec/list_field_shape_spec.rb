require "spec_helper"
require "tmpdir"
require "fileutils"

# A `list_of` field of a value object holds an Array whatever its element type: a lone scalar
# is refused, each element is checked as the element type, and nil stays legitimate.
RSpec.describe "a value object's list_of field" do
  SHELVING_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shelving" do
      vision "Items carrying a bag of tags."

      aggregate "Item" do
        description "An item."
        attribute :key, Key
        attribute :bag, Bag
        identified_by :key

        value_object "Key" do
          attribute :value, String
        end

        value_object "Bag" do
          attribute :heard, String
          attribute :tags, list_of(String)
          attribute :counts, list_of(Integer)
        end

        command "Make" do
          attribute :key, Key
          attribute :bag, Bag
          sets :bag
          emits Made
        end
      end
    end
  RUBY

  around do |example|
    Dir.mktmpdir("shelving") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bluebook"))
      File.write(File.join(dir, "bluebook/shelving.bluebook"), SHELVING_BLUEBOOK)
      @runtime = Hecks.boot(dir, install_doors: false)
      example.run
    end
  end

  def make(bag) = @runtime.dispatch("Shelving::Item.Make", with: { key: { value: rand.to_s }, bag: bag })

  it "takes an Array of the element type, or nothing", :aggregate_failures do
    expect { make(heard: "a", tags: %w[x y], counts: [1]) }.not_to raise_error
    expect { make(heard: "a") }.not_to raise_error
    expect { make(heard: "a", tags: nil) }.not_to raise_error
  end

  it "refuses a lone scalar where a list is declared", :aggregate_failures do
    expect { make(heard: "a", tags: "x") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /Bag\.tags expects list_of\(String\), got "x"/)
    expect { make(heard: "a", counts: 3) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /Bag\.counts expects list_of\(Integer\)/)
  end

  it "refuses a Hash where a list is declared" do
    expect { make(heard: "a", tags: { a: 1 }) }.to raise_error(Hecks::Runtime::TypeMismatch, /Bag\.tags/)
  end

  it "checks each element as the element type", :aggregate_failures do
    expect { make(heard: "a", tags: [1]) }.to raise_error(Hecks::Runtime::TypeMismatch, /Bag\.tags expects String/)
    expect { make(heard: "a", counts: ["1"]) }.to raise_error(Hecks::Runtime::TypeMismatch, /Bag\.counts/)
  end
end

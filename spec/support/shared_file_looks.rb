require_relative "impediment_looks"

# Three started work items for the impediment view's shared-files signal, with the branches a
# look reads stood in: `one` and `two` both change lib/b.rb, `three` shares nothing. A group
# changes `tips` or `files` to move a tip or a file.
RSpec.shared_context "with open branches that share a file" do
  include_context "with a stall watch tap"
  include ImpedimentLooks

  let(:tips) { { "one" => "aaa1111", "two" => "bbb2222", "three" => "ccc3333" } }
  let(:files) { { "one" => %w[lib/a.rb lib/b.rb], "two" => %w[lib/b.rb lib/c.rb], "three" => %w[lib/z.rb] } }
  let(:started) { %w[one two three].map { |key| ["WorkStarted", key, 50, "Tickets::Work"] } }

  # Each tip was committed ten minutes ago.
  def branch_read
    lambda do |keys|
      keys.map { |key| { branch: key, tip: tips[key], at: (Time.now.utc - 600).iso8601, files: files[key] } }
    end
  end

  def pair = row_of("branches-share-files")

  # The tap's lines as a look reads them.
  def tap_lines = File.readlines(tap).map { |text| JSON.parse(text) }
end

require "fileutils"

# The shop a rehearsal is run on: a small domain whose widgets named their size a band, copied
# beside a JSON document that holds its previous era and the records stored under it.
#
# The edge that leads the previous shape to the current one is written here, not kept as a
# `.bluebook` under spec/fixtures: every file there is a chapter the corpus parses, and an edge
# is not one.
module RehearsalShop
  SOURCE = File.expand_path("../fixtures/rehearsal/shop", __dir__)
  PREVIOUS_LABEL = "708420".freeze
  CURRENT_LABEL = "7edd70".freeze

  EDGE = <<~RUBY.freeze
    # The shop's widgets named their size a band, and the band became a closed set.
    Hecks.data_translation "Shop", from: "#{PREVIOUS_LABEL}", to: "#{CURRENT_LABEL}" do
      aggregate "Widget" do
        rename :size, to: :band
      end
    end
  RUBY

  # @param directory [String] where the shop is copied to
  # @param edge [Boolean] whether the edge to the current shape is written beside it
  # @return [String] the directory
  def self.copy_to(directory, edge: true)
    FileUtils.cp_r(SOURCE, directory)
    write_edge(directory) if edge
    directory
  end

  # @param directory [String] a copy of the shop
  # @return [void]
  def self.write_edge(directory)
    translations = File.join(directory, "bluebook", "translations")
    FileUtils.mkdir_p(translations)
    File.write(File.join(translations, "2-#{CURRENT_LABEL}.bluebook"), EDGE)
  end
end

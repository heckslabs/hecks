require "spec_helper"
require_relative "support/doctest"
require_relative "support/doctest_names"

# Runs every example on the reference pages; presence of an example is
# spec/reference_golden_spec.rb's question.
#
# Each page boots once in its hand-written preamble, and the words' examples run against that boot.
RSpec.describe "the DSL reference's examples" do
  def self.postgres_page?(path) = Doctest.parse(path).postgres

  # A page that declares adapter rows needs the parser, so it is `io` and rspec_rust_parser runs it.
  def self.io_page?(path) = postgres_page?(path) || Doctest.parser_page?(path)

  DoctestNames.reference.each do |path|
    it "#{File.basename(path)} says nothing its examples cannot back", io: io_page?(path) do
      skip "no reachable Postgres — start one to run this page" if self.class.postgres_page?(path) && !Doctest.postgres_available?

      expect(Doctest.run(path)).to be(true)
    end
  end
end

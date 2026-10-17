require "rspec/core"
require "hecks/composer"

# Specs that run the Composer's check need `hecks-parse`, the Rust parser. A group that includes
# this context builds it once, as spec/parser_parity_spec.rb does, and fails when it cannot: a
# skip would pass a CI job that never ran the check. The group is tagged `:io`, so the job that
# builds the parser (ci-rust-parser.yml) runs it and the unbuilt-parser shards leave it out.
module HecksParseBinary
  DIR = File.expand_path("../../rust/parser", __dir__)

  module_function

  # Builds the parser unless a binary is already where {Hecks::Composer::Parse} looks.
  #
  # @return [void]
  # @raise [RuntimeError] when `cargo build` fails or leaves no binary
  def build!
    Hecks::Composer::Parse.binary
  rescue Hecks::Composer::Parse::ParserMissing
    built = system("cargo", "build", chdir: DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built

    Hecks::Composer::Parse.binary
  end
end

# A group body still runs when `io: true` excludes its examples, so the build lives in a hook.
RSpec.shared_context "with the hecks-parse binary" do
  before(:context) { HecksParseBinary.build! }
end

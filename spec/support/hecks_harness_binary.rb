require "rspec/core"
require "hecks/harness/supervisor"
require "hecks/rust_build/build_lock"

# Specs that run the Harness need `hecks-harness`, the supervisor in rust/harness. A group that
# includes this context builds it once and fails when it cannot: a skip would pass a CI job that
# never ran the exchange. The group is tagged `:io`, so only the job that builds Rust runs it.
module HecksHarnessBinary
  DIR = File.expand_path("../../rust/harness", __dir__)

  module_function

  # Builds the supervisor unless a binary is already where {Hecks::Harness::Supervisor} looks.
  #
  # @return [String] the binary
  # @raise [RuntimeError] when `cargo build` fails or leaves no binary
  def build!
    binary = Hecks::Harness::Supervisor::BINARY
    return binary if File.executable?(binary)

    built = Hecks::RustBuild::BuildLock.hold { |held| system(held, "cargo", "build", chdir: DIR, out: File::NULL, err: File::NULL) }
    return binary if built && File.executable?(binary)

    raise "cargo build failed for rust/harness: run `cargo build` there directly to see why"
  end
end

# A group body still runs when `io: true` excludes its examples, so the build lives in a hook.
RSpec.shared_context "with the hecks-harness binary" do
  before(:context) { HecksHarnessBinary.build! }
end

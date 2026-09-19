require "spec_helper"
require "open3"
require "rbconfig"

# bin/rust_coverage's allowlist is shrink-only: each rule names a gap by
# kind + gap_class + construct, and `--check-allowlist` fails when a rule
# excuses no gap in any generated module. A closed gap must take its rule
# with it, rather than leave the rule behind to excuse the next one.
RSpec.describe "bin/rust_coverage --check-allowlist" do
  it "finds every allowlist rule still excusing a real gap under rust/src/generated" do
    output, status = Open3.capture2e(RbConfig.ruby, File.join(InMemoryDomain::ROOT, "bin/rust_coverage"),
                                     "--check-allowlist", chdir: InMemoryDomain::ROOT)

    expect(status).to be_success, output
  end
end

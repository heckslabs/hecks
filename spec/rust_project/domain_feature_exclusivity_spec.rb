require "spec_helper"
require "open3"

# Cargo features for separate domains are mutually exclusive: the default domain backs off when
# another is enabled, and two non-default domains fail with a named compile_error!.
# `io: true` -- real `cargo build` invocations.
RSpec.describe "Rust domain Cargo features are mutually exclusive (R5)", :io do
  DFE_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  def cargo_build(*args)
    stdout, stderr, status = Open3.capture3("cargo", "build", *args, chdir: DFE_RUST_DIR)
    [status.success?, stdout + stderr]
  end

  # Reads the real `default` from Cargo.toml: it tracks the last generated domain, so hardcoded
  # names could equal it and stop exercising the back-off.
  def current_default_domain
    toml = File.read(File.join(DFE_RUST_DIR, "Cargo.toml"))
    toml[/^default\s*=\s*\["([^"]+)"\]/, 1] or
      raise "could not find rust/Cargo.toml's own [features] default = [...] line"
  end

  def all_domain_features
    toml = File.read(File.join(DFE_RUST_DIR, "Cargo.toml"))
    section = toml[/^\[features\]\n(.*?)(?:\n\[|\z)/m, 1] or raise "no [features] section found"
    section.lines.filter_map { |line| line[/^(\w+)\s*=\s*\[\]/, 1] }
  end

  # Two domain features that are not the current default. Prefers banking/pizzas/roster, which CI
  # keeps buildable; other checked-in domains can be stale for unrelated reasons.
  PREFERRED_TEST_DOMAINS = %w[banking pizzas roster].freeze

  def two_non_default_domains
    non_default = all_domain_features - [current_default_domain]
    raise "need at least 2 non-default domain features to test against, found #{non_default.inspect}" if non_default.size < 2

    preferred = PREFERRED_TEST_DOMAINS & non_default
    (preferred + non_default).uniq.first(2)
  end

  it "`cargo build --features <a non-default domain>` succeeds WITHOUT --no-default-features" do
    # Must not be the current default, or this passes without exercising the back-off.
    # trivially without exercising the back-off mechanism at all.
    domain, = two_non_default_domains
    ok, output = cargo_build("--features", domain)
    expect(ok).to be(true), "cargo build --features #{domain} failed:\n#{output}"
  end

  it "a bare `cargo build` (whichever domain is currently `default`) still succeeds unaffected" do
    ok, output = cargo_build
    expect(ok).to be(true), "plain cargo build failed:\n#{output}"
  end

  # Two explicitly requested domains cannot both own `generated::active`: expect our named
  # compile_error!, not a bare "defined multiple times".
  it "two explicitly-requested, non-default domain features fail with a clear, named compile_error!" do
    domain_a, domain_b = two_non_default_domains
    ok, output = cargo_build("--features", "#{domain_a},#{domain_b}")
    expect(ok).to be(false), "expected --features #{domain_a},#{domain_b} to fail (both are real, non-default domains)"
    expect(output).to include("domain features are mutually exclusive")
    expect(output).to include(domain_a)
    expect(output).to include(domain_b)
  end

  # Root mod.rs gates each domain module behind its own Cargo feature, so a domain whose generated
  # code does not compile cannot break another feature's build. Breaks one domain's file and
  # checks the other; `ensure` restores it.
  it "a deliberately-broken generated module under feature A does not break feature B's build" do
    domain_a, domain_b = two_non_default_domains
    broken_file = Dir.glob(File.join(DFE_RUST_DIR, "src", "generated", domain_a, "*.rs"))
                     .find { |path| !%w[mod.rs merged.rs metadata.rs registry.rs].include?(File.basename(path)) }
    raise "no aggregate .rs file found under rust/src/generated/#{domain_a} to break" unless broken_file

    original = File.read(broken_file)
    begin
      marker = "compile_error!(\"BUG#25 regression spec — deliberately broken, should never reach feature #{domain_b}\");\n"
      File.write(broken_file, "#{original}\n#{marker}")

      ok_a, = cargo_build("--features", domain_a)
      expect(ok_a).to be(false), "expected --features #{domain_a} to fail against its own deliberately-broken module"

      ok_b, output_b = cargo_build("--features", domain_b)
      expect(ok_b).to be(true),
                      "cargo build --features #{domain_b} failed even though only #{domain_a}'s own module was broken " \
                      "— a broken/absent domain must never break a different feature's build (BUG#25):\n#{output_b}"
    ensure
      File.write(broken_file, original)
    end
  end
end

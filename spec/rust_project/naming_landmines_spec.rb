require "spec_helper"
require "open3"
require "tmpdir"
require_relative "../../rust/project/naming"

# R5 (docs/audits/2026-08-11-bug-triage.md) -- the "latent codegen
# landmines" half of the finding: bin/project_rust's domain-name
# handling and .inspect-based description embedding could silently
# produce Rust source that fails to compile, for two independent
# reasons this file tests directly (fast, no `cargo build` needed to
# prove the STRING-LEVEL fix is right -- the io-tagged spec alongside
# this one, domain_feature_exclusivity_spec.rb, additionally proves
# the real end-to-end build).
RSpec.describe RustProjection::Projector do
  describe ".valid_domain_mod_name?" do
    it "accepts ordinary lowercase domain names" do
      %w[banking pizzas roster my_domain a].each do |name|
        expect(described_class.valid_domain_mod_name?(name)).to be(true), "expected #{name.inspect} to be valid"
      end
    end

    # THE R5 LANDMINE ITSELF -- a domain literally named one of these
    # would have its Cargo.toml feature entry silently skipped by
    # bin/project_rust's (now [features]-scoped) sync regex, since each
    # one is also a real key elsewhere in rust/Cargo.toml ([package]'s
    # version/edition/name, [lib]/[[bin]]'s path) or Cargo's own
    # reserved feature-list name (default).
    it "rejects domain names that collide with a reserved Cargo.toml key" do
      %w[version edition path default name lib bin package].each do |name|
        expect(described_class.valid_domain_mod_name?(name)).to be(false), "expected #{name.inspect} to be rejected"
      end
    end

    it "rejects domain names that are Rust keywords (would break `pub mod <name>;`)" do
      %w[type self mod crate move fn].each do |name|
        expect(described_class.valid_domain_mod_name?(name)).to be(false), "expected #{name.inspect} to be rejected"
      end
    end

    it "rejects domain names that aren't a legal bare Rust identifier" do
      ["2pizzas", "my-app", "", "Banking", "has space"].each do |name|
        expect(described_class.valid_domain_mod_name?(name)).to be(false), "expected #{name.inspect} to be rejected"
      end
    end
  end

  # BUG#124 -- an aggregate's own name has the same landmine class 2 as a
  # domain name's `pub mod #{name};` above, at a different site
  # (domain_generator.rb's per-aggregate file + `pub mod
  # #{a[:name].downcase};` in the domain's own mod.rs), keyed off the
  # DOWNCASED form since an aggregate is conventionally declared
  # PascalCase ("Crate") and it's the lowercase module identifier that
  # collides.
  describe ".valid_aggregate_mod_name?" do
    it "accepts ordinary PascalCase aggregate names" do
      %w[Roster Pizza MyAggregate A].each do |name|
        expect(described_class.valid_aggregate_mod_name?(name)).to be(true), "expected #{name.inspect} to be valid"
      end
    end

    # THE BUG#124 LANDMINE ITSELF -- downcased, each of these becomes a
    # Rust keyword as a bare module identifier (`pub mod crate;`),
    # exactly the shape `bin/qa_generated_domains --rust` found live
    # against qa/stress_domains/generated_keyword_aggregate.
    it "rejects aggregate names that downcase to a Rust keyword (would break `pub mod <name>;`)" do
      %w[Crate Self Type Move Fn Mod Self].each do |name|
        expect(described_class.valid_aggregate_mod_name?(name)).to be(false), "expected #{name.inspect} to be rejected"
      end
    end

    it "rejects aggregate names that aren't a legal bare Rust identifier once downcased" do
      ["2Crate", "My-App", ""].each do |name|
        expect(described_class.valid_aggregate_mod_name?(name)).to be(false), "expected #{name.inspect} to be rejected"
      end
    end

    # UNLIKE a domain name, an aggregate name never doubles as a Cargo
    # feature key -- only the DOMAIN'S OWN directory name does
    # (CARGO_RESERVED_DOMAIN_NAMES's own header). "version"/"default"/etc
    # are perfectly fine aggregate names.
    it "accepts aggregate names that collide with a Cargo.toml key (no feature-name role to collide with)" do
      %w[Version Default Package].each do |name|
        expect(described_class.valid_aggregate_mod_name?(name)).to be(true), "expected #{name.inspect} to be accepted"
      end
    end
  end

  describe ".rust_ident_field" do
    it "raw-escapes an ordinary Rust keyword field name" do
      expect(described_class.rust_ident_field("type")).to eq("r#type")
      expect(described_class.rust_ident_field("fn")).to eq("r#fn")
    end

    it "leaves an ordinary field name untouched" do
      expect(described_class.rust_ident_field("code")).to eq("code")
    end

    # THE SAME LANDMINE CLASS AS BUG#124's aggregate-name collision, at
    # the struct-field site: crate/self/super/Self cannot be rescued by
    # a raw identifier AT ALL (not a matter of position) -- per the Rust
    # reference's own RAW_IDENTIFIER grammar, `r#crate` etc. are not
    # valid raw-identifier syntax, full stop. Refuse loudly rather than
    # silently emit that broken syntax.
    it "refuses to raw-escape crate/self/super/Self -- no raw identifier rescues them" do
      %w[crate self super Self].each do |field|
        expect { described_class.rust_ident_field(field) }.to raise_error(/cannot be rescued by a raw identifier/)
      end
    end
  end

  describe ".rust_string_literal" do
    let(:hash_char) { "#" }

    # Ruby's own String#inspect escapes a literal #{ / #@ as \#{ / \#@
    # (Ruby-source-safety escaping -- meaningful only when the inspected
    # text is later re-read as a RUBY double-quoted string) and a
    # control character as bare \uXXXX (Ruby's own escape, missing
    # Rust's required braces). Neither is a legal Rust escape.
    # rust_string_literal must do neither.
    it "leaves a literal hash-brace / hash-at untouched -- Rust has no interpolation syntax to escape" do
      source = "cost must be over #{hash_char}{threshold}"
      described = described_class.rust_string_literal(source)
      expect(described).to eq("\"#{source}\"")

      source_ivar = "ivar #{hash_char}@foo"
      described_ivar = described_class.rust_string_literal(source_ivar)
      expect(described_ivar).to eq("\"#{source_ivar}\"")
    end

    it "escapes a raw control character as a BRACED \\u{...} (Rust's own syntax, unlike Ruby's bare \\uXXXX)" do
      described = described_class.rust_string_literal("control:#{1.chr}:end")
      expect(described).to eq('"control:\u{1}:end"')
      expect(described).not_to include("\\u0001") # Ruby's own (invalid-in-Rust, brace-less) rendering
    end

    it "still escapes backslash, double-quote, and the common whitespace escapes correctly" do
      expect(described_class.rust_string_literal('quote"and\\slash')).to eq('"quote\"and\\\\slash"')
      expect(described_class.rust_string_literal("tab\tand\nnewline")).to eq('"tab\tand\nnewline"')
    end

    it "leaves ordinary text identical to Ruby's own #inspect" do
      plain = "an ordinary description, nothing special"
      expect(described_class.rust_string_literal(plain)).to eq(plain.inspect)
    end

    # THE REAL PROOF, NOT JUST A STRING COMPARISON -- feed rustc the
    # exact landmine inputs (a literal #{, #@, and a control character)
    # run through the real function, and confirm the resulting .rs file
    # actually compiles. io: true -- a real rustc subprocess, same
    # convention as every other spec doing real, uncontrolled I/O.
    it "produces Rust source that actually compiles, for every landmine input at once", :io do
      landmine = "cost must be over #{hash_char}{threshold}, ivar #{hash_char}@foo, control:#{1.chr}:end, quote\"and\\slash"
      literal = described_class.rust_string_literal(landmine)

      Dir.mktmpdir("r5-rust-string-literal-spec") do |dir|
        src = File.join(dir, "landmine.rs")
        File.write(src, "fn main() {\n    let s: &str = #{literal};\n    println!(\"{}\", s);\n}\n")

        out_binary = File.join(dir, "landmine")
        rustc = ENV["HECKS_RUSTC"] || "rustc"
        _stdout, stderr, status = Open3.capture3(rustc, src, "-o", out_binary)
        expect(status.success?).to be(true), "generated Rust source failed to compile:\n#{stderr}\n\nsource:\n#{File.read(src)}"
        expect(File.executable?(out_binary)).to be(true)
      end
    end
  end
end

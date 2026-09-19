require "spec_helper"
require "open3"
require "tmpdir"
require_relative "../../rust/project/naming"

# R5 (docs/audits/2026-08-11-bug-triage.md) -- the "latent codegen
# landmines" half of the finding: bin/project_rust's domain-name
# handling and .inspect-based description embedding could silently
# produce Rust source that fails to compile, for two independent
# reasons this file tests directly (fast, no `cargo build` needed to
# prove the string-level fix is right -- the io-tagged spec alongside
# this one, domain_feature_exclusivity_spec.rb, additionally proves
# the real end-to-end build).
#
# Reserved-word collisions (a domain or aggregate module name that is a
# Rust keyword or a reserved Cargo.toml key, BUG#124) are the shared
# `Hecks::Bluebook::ModelCheck.rust_reserved_name_findings` check now, and
# are pinned by spec/model_check_spec.rb's "Rust reserved names" table.
# This file keeps only the identifier-shape and escaping rules.
RSpec.describe RustProjection::Projector do
  describe ".valid_domain_mod_name?" do
    it "accepts ordinary lowercase domain names" do
      %w[banking pizzas roster my_domain a].each do |name|
        expect(described_class.valid_domain_mod_name?(name)).to be(true), "expected #{name.inspect} to be valid"
      end
    end

    it "rejects domain names that aren't a legal bare Rust identifier" do
      ["2pizzas", "my-app", "", "Banking", "has space"].each do |name|
        expect(described_class.valid_domain_mod_name?(name)).to be(false), "expected #{name.inspect} to be rejected"
      end
    end
  end

  describe ".legal_aggregate_mod_identifier?" do
    it "accepts ordinary PascalCase aggregate names" do
      %w[Roster Pizza MyAggregate A].each do |name|
        expect(described_class.legal_aggregate_mod_identifier?(name)).to be(true), "expected #{name.inspect} to be valid"
      end
    end

    it "rejects aggregate names that aren't a legal bare Rust identifier once downcased" do
      ["2Crate", "My-App", ""].each do |name|
        expect(described_class.legal_aggregate_mod_identifier?(name)).to be(false),
                                                                         "expected #{name.inspect} to be rejected"
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

    # The same landmine class as BUG#124's aggregate-name collision, at
    # the struct-field site: crate/self/super/Self cannot be rescued by
    # a raw identifier at all (not a matter of position) -- per the Rust
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
    # text is later re-read as a Ruby double-quoted string) and a
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
      # Ruby's own (invalid-in-Rust, brace-less) rendering
      expect(described).not_to include("\\u0001")
    end

    it "still escapes backslash, double-quote, and the common whitespace escapes correctly" do
      expect(described_class.rust_string_literal('quote"and\\slash')).to eq('"quote\"and\\\\slash"')
      expect(described_class.rust_string_literal("tab\tand\nnewline")).to eq('"tab\tand\nnewline"')
    end

    it "leaves ordinary text identical to Ruby's own #inspect" do
      plain = "an ordinary description, nothing special"
      expect(described_class.rust_string_literal(plain)).to eq(plain.inspect)
    end

    # The real proof, not just a string comparison -- feed rustc the
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

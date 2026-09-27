require "spec_helper"
require "open3"
require "tmpdir"
require_relative "../../rust/project/naming"

# String-level tests for bin/project_rust's domain-name handling and string-literal escaping;
# domain_feature_exclusivity_spec.rb covers the real build. Reserved-word collisions are pinned
# by spec/model_check_spec.rb ("Rust reserved names").
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

    # crate/self/super/Self are not valid raw identifiers (`r#crate`), so refuse loudly.
    it "refuses to raw-escape crate/self/super/Self -- no raw identifier rescues them" do
      %w[crate self super Self].each do |field|
        expect { described_class.rust_ident_field(field) }.to raise_error(/cannot be rescued by a raw identifier/)
      end
    end
  end

  describe ".rust_string_literal" do
    let(:hash_char) { "#" }

    # String#inspect escapes #{ / #@ (Ruby-only) and emits bare \uXXXX without Rust's braces;
    # neither is a legal Rust escape, so rust_string_literal must do neither.
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

    # Feeds rustc the landmine inputs and confirms the source compiles; `io: true` for rustc.
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

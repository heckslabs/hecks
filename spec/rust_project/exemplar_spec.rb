require "tmpdir"
require_relative "../../rust/project/exemplar"

# THE LOADER, TESTED IN ISOLATION — against a small scratch fixture tree,
# never the real rust/src/exemplar/*.rs (that tree is proven valid by
# `cargo test --lib` instead; this spec proves the RUBY side of the
# pipeline: fence-parsing, substitution, drift detection, nested-slot
# composition). `Exemplar.reset!(dir: ...)` repoints the loader at each
# example's own fixture directory.
RSpec.describe RustProjection::Exemplar do
  after { described_class.reset! } # back to the real tree; no stale fixture dir leaks into later specs

  def write_fixture(contents)
    dir = Dir.mktmpdir("exemplar_spec")
    File.write(File.join(dir, "fixture.rs"), contents)
    RustProjection::Exemplar.reset!(dir: dir)
    dir
  end

  describe ".render" do
    it "substitutes every marker and returns the dedented shape text" do
      write_fixture(<<~RUST)
        fn tmpl_host(tmpl_scalar: String) -> Result<(), ()> {
            // TMPL:leaf BEGIN
            if !tmpl_scalar.is_empty() { return Ok(()); }
            // TMPL:leaf END
            Ok(())
        }
      RUST

      out = described_class.render("leaf", "tmpl_scalar" => "self.balance")

      expect(out).to eq("if !self.balance.is_empty() { return Ok(()); }")
    end

    it "substitutes the longest marker first so one marker can't eat part of another" do
      write_fixture(<<~RUST)
        // TMPL:leaf BEGIN
        tmpl_field + tmpl_field_extra
        // TMPL:leaf END
      RUST

      out = described_class.render("leaf", "tmpl_field" => "balance", "tmpl_field_extra" => "fees")

      expect(out).to eq("balance + fees")
    end

    it "raises when a shape id doesn't exist" do
      write_fixture("// nothing fenced here\n")

      expect { described_class.render("missing", {}) }.to raise_error(described_class::DriftError, /no shape "missing"/)
    end

    it "raises when subs names a marker the shape text doesn't contain (exemplar/caller drift)" do
      write_fixture(<<~RUST)
        // TMPL:leaf BEGIN
        tmpl_field
        // TMPL:leaf END
      RUST

      expect { described_class.render("leaf", "tmpl_field" => "balance", "tmpl_other" => "x") }
        .to raise_error(described_class::DriftError, /tmpl_other.*not found/)
    end

    it "raises when a real placeholder is left unrendered" do
      write_fixture(<<~RUST)
        // TMPL:leaf BEGIN
        tmpl_field + tmpl_other
        // TMPL:leaf END
      RUST

      expect { described_class.render("leaf", "tmpl_field" => "balance") }
        .to raise_error(described_class::DriftError, /unrendered placeholder.*tmpl_other/)
    end
  end

  describe ".render_each" do
    it "renders once per entry and joins" do
      write_fixture(<<~RUST)
        // TMPL:arm BEGIN
        "tmpl_field" => self.tmpl_field.clone(),
        // TMPL:arm END
      RUST

      out = described_class.render_each("arm", [{ "tmpl_field" => "balance" }, { "tmpl_field" => "currency" }])

      expect(out).to eq(<<~RUST.strip)
        "balance" => self.balance.clone(),
        "currency" => self.currency.clone(),
      RUST
    end
  end

  describe ".compose" do
    it "renders the inner shape once per field, splices it into the outer skeleton's slot, then substitutes " \
       "the outer's own markers" do
      write_fixture(<<~RUST)
        // TMPL:record_struct BEGIN
        pub struct TmplType {
            // TMPL:record_struct:FIELD BEGIN
            pub tmpl_field: i64,
            // TMPL:record_struct:FIELD END
        }
        // TMPL:record_struct END
      RUST

      out = described_class.compose(
        "record_struct",
        { "TmplType" => "Account" },
        field_id:        "record_struct:FIELD",
        field_subs_list: [{ "tmpl_field" => "balance" }, { "tmpl_field" => "currency" }]
      )

      expect(out).to eq(<<~RUST.strip)
        pub struct Account {
            pub balance: i64,
            pub currency: i64,
        }
      RUST
    end

    it "raises when the outer shape has no nested slot for field_id" do
      write_fixture(<<~RUST)
        // TMPL:record_struct BEGIN
        pub struct TmplType {}
        // TMPL:record_struct END
      RUST

      expect do
        described_class.compose("record_struct", {}, field_id: "record_struct:FIELD", field_subs_list: [])
      end.to raise_error(described_class::DriftError, /no nested slot/)
    end
  end

  describe ".assemble" do
    # A single input->exact-output assertion; the length is the fixture
    # source and the expected rendered text (both slots, in one outer
    # shape, are the point), not several things happening in sequence.
    # rubocop:disable-next RSpec/ExampleLength
    it "fills TWO independent slots in one outer shape, each reindented by its own marker's position" do
      write_fixture(<<~RUST)
        // TMPL:codec BEGIN
        impl TmplType {
            pub fn to_json(&self) {
                match self {
                    // TMPL:codec:TO_JSON_ARM BEGIN
                    TmplType::TmplMemberA => "tmpl_member_a",
                    // TMPL:codec:TO_JSON_ARM END
                }
            }
            pub fn from_json() {
                match raw {
                    // TMPL:codec:FROM_JSON_ARM BEGIN
                    "tmpl_member_a" => Ok(TmplType::TmplMemberA),
                    // TMPL:codec:FROM_JSON_ARM END
                }
            }
        }
        // TMPL:codec END
      RUST

      row_subs = [{ "TmplType" => "Kind", "TmplMemberA" => "A", '"tmpl_member_a"' => '"a"' }]
      out = described_class.assemble(
        "codec",
        { "TmplType" => "Kind" },
        slots: {
          "codec:TO_JSON_ARM"   => described_class.render_each("codec:TO_JSON_ARM", row_subs),
          "codec:FROM_JSON_ARM" => described_class.render_each("codec:FROM_JSON_ARM", row_subs)
        }
      )

      expect(out).to eq(<<~RUST.strip)
        impl Kind {
            pub fn to_json(&self) {
                match self {
                    Kind::A => "a",
                }
            }
            pub fn from_json() {
                match raw {
                    "a" => Ok(Kind::A),
                }
            }
        }
      RUST
    end

    it "raises when a slots key names a marker with no nested region" do
      write_fixture(<<~RUST)
        // TMPL:codec BEGIN
        impl TmplType {}
        // TMPL:codec END
      RUST

      expect do
        described_class.assemble("codec", {}, slots: { "codec:MISSING" => "x" })
      end.to raise_error(described_class::DriftError, /no nested slot/)
    end
  end

  describe "against the real exemplar tree" do
    it "loads the real rust/src/exemplar/*.rs shapes without raising" do
      expect { described_class.shapes }.not_to raise_error
      expect(described_class.shapes.keys).to include(
        "admits_check", "pattern_check", "role_check", "with_value_literal_fn",
        "closed_set_enum", "closed_set_enum:VARIANT",
        "closed_set_codec", "closed_set_codec:TO_JSON_ARM", "closed_set_codec:FROM_JSON_ARM",
        "plain_struct", "struct_field",
        "closed_set_table_row_field", "to_json_field",
        "closed_set_table_codec", "closed_set_table_from_json_condition"
      )
    end

    it "renders the real plain_struct shape for a two-field value object" do
      out = described_class.compose(
        "plain_struct",
        { "TmplType" => "AccountNumber" },
        field_id:        "struct_field",
        field_subs_list: [{ "TmplFieldType" => "String", "tmpl_field" => "value" }]
      )

      expect(out).to eq(<<~RUST.strip)
        #[derive(Debug, Clone, PartialEq)]
        pub struct AccountNumber {
            pub value: String,
        }
      RUST
    end

    it "renders the real closed_set_table_row_field shape, no trailing comma (Ruby supplies the join)" do
      out = described_class.render("closed_set_table_row_field", "tmpl_field"               => "cadence",
                                                                 "tmpl_value_placeholder()" => '"monthly"')
      expect(out).to eq('cadence: "monthly"')
    end

    # A single input->exact-output assertion against the real checked-in
    # codec; the length is the pinned expected Rust source, not multiple
    # separate claims.
    # rubocop:disable-next RSpec/ExampleLength
    it "renders the real closed_set_table_codec shape, matching the checked-in StatementFrequency codec" do
      to_json_line = '        ("cadence".to_string(), crate::kernel::Json::Str(self.cadence.to_string())),'

      out = described_class.render(
        "closed_set_table_codec",
        "TmplTableRow"                => "StatementFrequency",
        "tmpl_to_json_fields_block()" => to_json_line,
        "TMPL_TABLE"                  => "STATEMENT_FREQUENCY",
        "tmpl_from_json_conditions()" => 'v.get("cadence").and_then(crate::kernel::Json::as_str) == Some(row.cadence)'
      )

      expect(out).to eq([
        "impl StatementFrequency {",
        "    pub fn to_json(&self) -> crate::kernel::Json {",
        "        crate::kernel::Json::Object(vec![",
        to_json_line,
        "        ])",
        "    }",
        "",
        "    pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {",
        "        for row in STATEMENT_FREQUENCY {",
        '            if v.get("cadence").and_then(crate::kernel::Json::as_str) == Some(row.cadence) {',
        "                return Ok(row.clone());",
        "            }",
        "        }",
        '        Err(crate::kernel::Refusal::TypeMismatch(format!("StatementFrequency: no member matches {:?}", v)))',
        "    }",
        "}"
      ].join("\n"))
    end

    it "renders the real closed_set_enum shape for a two-member set" do
      out = described_class.compose(
        "closed_set_enum",
        { "TmplKind" => "LedgerDirection" },
        field_id:        "closed_set_enum:VARIANT",
        field_subs_list: [{ "TmplMemberA" => "Credit" }, { "TmplMemberA" => "Debit" }]
      )

      expect(out).to eq(<<~RUST.strip)
        #[derive(Debug, Clone, PartialEq, Eq)]
        pub enum LedgerDirection {
            Credit,
            Debit,
        }
      RUST
    end

    # A single input->exact-output assertion against the real checked-in
    # codec, both slots (to_json/from_json); the length is the pinned
    # expected Rust source, not multiple separate claims.
    # rubocop:disable-next RSpec/ExampleLength
    it "renders the real closed_set_codec shape, both slots, matching the checked-in LedgerDirection codec" do
      row_subs = [
        { "TmplKind" => "LedgerDirection", "TmplMemberA" => "Credit", '"tmpl_member_a"' => '"credit"' },
        { "TmplKind" => "LedgerDirection", "TmplMemberA" => "Debit", '"tmpl_member_a"' => '"debit"' }
      ]

      out = described_class.assemble(
        "closed_set_codec",
        {
          "TmplKind"                   => "LedgerDirection",
          '"tmpl_field_name"'          => '"value"',
          "tmpl_field_name"            => "value",
          '"tmpl_closed_set_type"'     => '"LedgerDirection"',
          '"tmpl_closed_set_admitted"' => '"\"credit\", \"debit\""'
        },
        slots: {
          "closed_set_codec:TO_JSON_ARM"   => described_class.render_each("closed_set_codec:TO_JSON_ARM", row_subs),
          "closed_set_codec:FROM_JSON_ARM" => described_class.render_each("closed_set_codec:FROM_JSON_ARM", row_subs)
        }
      )

      expect(out).to eq(<<~RUST.strip)
        impl LedgerDirection {
            pub fn to_json(&self) -> crate::kernel::Json {
                let member = match self {
                    LedgerDirection::Credit => "credit",
                    LedgerDirection::Debit => "debit",
                };
                crate::kernel::Json::obj(vec![("value", crate::kernel::Json::str(member))])
            }

            pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
                let raw = v.require("value", "LedgerDirection")?.as_str()
                    .ok_or_else(|| crate::kernel::Refusal::TypeMismatch("LedgerDirection.value: expected string".to_string()))?;
                match raw {
                    "credit" => Ok(LedgerDirection::Credit),
                    "debit" => Ok(LedgerDirection::Debit),
                    other => Err(crate::kernel::Refusal::InvariantViolation(crate::kernel::RefusalSite::InvariantViolationClosedSetMember.render(&[
                        ("type", "LedgerDirection"),
                        ("admitted", "\\"credit\\", \\"debit\\""),
                        ("offered", &format!("{:?}", other)),
                    ]))),
                }
            }
        }
      RUST
    end

    it "renders the real admits_check shape" do
      out = described_class.render(
        "admits_check",
        '["tmpl_member_a", "tmpl_member_b"]' => '["credit", "debit"]',
        "tmpl_scalar"                        => "args.direction.value",
        '"tmpl_prefix_text"'                 => '"direction admits Account::LedgerDirection — \"credit\", \"debit\" — got "'
      )

      expect(out).to eq(
        'if !["credit", "debit"].contains(&args.direction.value.as_str()) { return Err(crate::kernel::Refusal::' \
        'InvariantViolation(format!("{}{:?}", "direction admits Account::LedgerDirection — \"credit\", ' \
        '\"debit\" — got ", args.direction.value))); }'
      )
    end
  end
end

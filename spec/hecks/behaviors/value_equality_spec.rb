# spec/hecks/behaviors/value_equality_spec.rb
#
# Regression tests for the seven cascade-dropping Ruby↔Rust value
# equality divergences catalogued in PR #264's audit
# (`VALUE_EQUALITY_AUDIT.md`).
#
# Each test case is keyed by the audit case number so a future
# reader can cross-reference the report. The expected value is the
# post-fix Ruby answer — in most cases "false" because the fix
# short-circuits display-form fallback for Null/List/Map kinds and
# tightens numeric string coercion to reject whitespace. One case
# (34, map insertion order) flips from false to true because the
# newly-structural `Value#==` means `Hash#==` is order-insensitive.
#
# [antibody-exempt: regression tests for the above; retires with the Ruby runner]
#
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks/behaviors/value"

RSpec.describe Hecks::Behaviors::Value do
  V = described_class

  # Shortcuts for the five kinds, keyed to Rust's `Value` enum.
  def i(n);  V.new(:int,  n);             end
  def s(t);  V.new(:str,  t);             end
  def b(x);  V.new(:bool, x);             end
  def nul;   V.new(:null, nil);           end
  def lst(*xs); V.new(:list, xs);         end
  def mp(h);  V.new(:map,  h);            end

  describe "structural equality (#==, #eql?, #hash)" do
    # Without a custom `==`, `raw == raw` on nested lists/maps fell
    # through to object identity — the latent bug flagged as class 5
    # in the audit. These tests pin the structural contract.
    it "equates two Int values with the same raw" do
      expect(i(1) == i(1)).to eq(true)
      expect(i(1).eql?(i(1))).to eq(true)
      expect(i(1).hash).to eq(i(1).hash)
    end

    it "distinguishes Values by kind" do
      expect(i(1) == s("1")).to eq(false)
    end

    it "equates nested lists element-wise" do
      expect(lst(i(1), i(2)) == lst(i(1), i(2))).to eq(true)
      expect(lst(i(1), i(2)) == lst(i(2), i(1))).to eq(false)
    end

    it "equates maps order-insensitively (Hash#== semantics)" do
      expect(mp({ a: i(1), b: i(2) }) == mp({ b: i(2), a: i(1) })).to eq(true)
    end

    it "is not equal to non-Value objects" do
      expect(i(1) == 1).to eq(false)
      expect(i(1) == "1").to eq(false)
    end
  end

  describe ".equal? (loose equality with coercion)" do
    # Baseline sanity — the scalar cases from the audit that already
    # agree (and must stay agreeing).
    it "agrees on Int(0) == Str(\"0\")" do
      expect(V.equal?(i(0), s("0"))).to eq(true)
    end

    it "agrees on Bool(true) == Str(\"true\")" do
      expect(V.equal?(b(true), s("true"))).to eq(true)
    end

    it "agrees on Null == Int(0) (via numeric coercion, 0.0 == 0.0)" do
      expect(V.equal?(nul, i(0))).to eq(true)
    end

    # ----- the 7 cascade-dropping fixes -----

    # Case 8 — Null == Str("null") — PR #262 short-circuits display
    # fallback on :null, keeping the Ruby answer at false (the Rust
    # runner diverges at true; audit flags for a separate Rust fix).
    it "case 8: Null is not equal to Str(\"null\") via display" do
      expect(V.equal?(nul, s("null"))).to eq(false)
      expect(V.equal?(s("null"), nul)).to eq(false)
    end

    # Case 16 — numeric coercion must reject leading/trailing whitespace
    # to mirror Rust's `s.parse::<f64>()`.
    it "case 16: Str(\" 1 \") is not equal to Int(1) (whitespace rejected)" do
      expect(V.equal?(s(" 1 "), i(1))).to eq(false)
      expect(V.equal?(i(1), s(" 1 "))).to eq(false)
    end

    it "case 16 corollary: non-numeric strings still fail coercion" do
      expect(V.equal?(s("abc"), i(0))).to eq(false)
    end

    it "case 16 corollary: scientific notation still coerces" do
      expect(V.equal?(s("1e3"), i(1000))).to eq(true)
    end

    # Case 27 — list order matters (structural, positional).
    it "case 27: [1,2] is not equal to [2,1] (order preserved)" do
      expect(V.equal?(lst(i(1), i(2)), lst(i(2), i(1)))).to eq(false)
    end

    # Case 28 — same-length different-content lists are unequal.
    it "case 28: [1,2] is not equal to [3,4] (no display collision)" do
      expect(V.equal?(lst(i(1), i(2)), lst(i(3), i(4)))).to eq(false)
    end

    # Case 30 — an empty list is not equal to the literal string "[]".
    # Structural-only for :list kills the display-form fallback.
    it "case 30: [] is not equal to Str(\"[]\")" do
      expect(V.equal?(lst, s("[]"))).to eq(false)
      expect(V.equal?(s("[]"), lst)).to eq(false)
    end

    # Case 31 — display-form leakage in the other direction.
    it "case 31: [] is not equal to Str(\"[0 items]\")" do
      expect(V.equal?(lst, s("[0 items]"))).to eq(false)
    end

    # Case 33 — same-size different-keys maps are unequal.
    it "case 33: {a:1} is not equal to {b:1}" do
      expect(V.equal?(mp({ a: i(1) }), mp({ b: i(1) }))).to eq(false)
    end

    # Case 34 — map insertion order is irrelevant once Value has a
    # structural `==` (Ruby's Hash#== is order-independent). This is
    # the one case where the fix flips the answer from false to true.
    it "case 34: {a:1,b:2} equals {b:2,a:1} (insertion-order independent)" do
      expect(V.equal?(
        mp({ a: i(1), b: i(2) }),
        mp({ b: i(2), a: i(1) })
      )).to eq(true)
    end

    # Case 36 — an empty map is not equal to the literal string "{}".
    it "case 36: {} is not equal to Str(\"{}\")" do
      expect(V.equal?(mp({}), s("{}"))).to eq(false)
    end

    # Case 39 — same-length lists with different string content are
    # unequal; structural positional equality (no display collision).
    it "case 39: [\"a\",\"b\"] is not equal to [\"c\",\"d\"]" do
      expect(V.equal?(
        lst(s("a"), s("b")),
        lst(s("c"), s("d"))
      )).to eq(false)
    end

    # Regression guards: PR #262's fix stays alive.
    it "pr #262: Null != Str(\"\")" do
      expect(V.equal?(nul, s(""))).to eq(false)
      expect(V.equal?(s(""), nul)).to eq(false)
    end
  end
end

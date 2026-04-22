#!/usr/bin/env ruby
# Value-equality parity harness
#
# Runs the SAME test pairs through two reference implementations:
#   - Ruby: the actual Hecks::Behaviors::Value in lib/hecks/behaviors/value.rb
#   - Rust: a line-faithful port of hecks_life/src/runtime/interpreter.rs
#           values_equal + numeric_value + Display for Value
#
# Emits a markdown table of (left, right, ruby, rust, agree?) rows.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "hecks/behaviors/value"

RubyValue = Hecks::Behaviors::Value

# --------------------------------------------------------------------
# Rust port — mirrors hecks_life/src/runtime/interpreter.rs exactly
# --------------------------------------------------------------------

module RustPort
  # Value variants: :int, :str, :bool, :list, :map, :null
  class V
    attr_reader :kind, :raw
    def initialize(kind, raw); @kind = kind; @raw = raw; end

    # Rust derives PartialEq on Value — structural equality.
    # HashMap<String, Value> equality ignores order; Vec<Value> is positional.
    def ==(other)
      return false unless other.is_a?(V)
      return false unless kind == other.kind
      case kind
      when :list
        return false unless raw.length == other.raw.length
        raw.each_with_index.all? { |x, i| x == other.raw[i] }
      when :map
        return false unless raw.size == other.raw.size
        raw.all? { |k, v| other.raw.key?(k) && other.raw[k] == v }
      else
        raw == other.raw
      end
    end
  end

  def self.display(v)
    case v.kind
    when :str  then v.raw.to_s
    when :int  then v.raw.to_s
    when :bool then v.raw ? "true" : "false"
    when :list then "[#{v.raw.length} items]"
    when :map  then "{#{v.raw.size} fields}"
    when :null then "null"
    end
  end

  # Exact port of numeric_value():
  #   Int(n) → n as f64; Bool true→1.0 false→0.0;
  #   Str(s) → s.parse::<f64>().ok(); Null → 0.0; List/Map → None
  def self.numeric(v)
    case v.kind
    when :int  then v.raw.to_f
    when :bool then v.raw ? 1.0 : 0.0
    when :str
      # Rust f64 parsing: accepts "1", "1.0", "1e3", ".5", "-1",
      # rejects "", "abc", "1 ", " 1" (leading/trailing spaces).
      s = v.raw
      return nil if s.nil? || s.empty?
      return nil if s != s.strip
      Float(s, exception: false)
    when :null then 0.0
    else nil
    end
  end

  def self.equal?(a, b)
    return true if a == b
    na = numeric(a); nb = numeric(b)
    return na == nb if na && nb
    display(a) == display(b)
  end
end

# --------------------------------------------------------------------
# Helpers to build values
# --------------------------------------------------------------------

def rb_int(n);    RubyValue.new(:int, n); end
def rb_str(s);    RubyValue.new(:str, s); end
def rb_bool(b);   RubyValue.new(:bool, b); end
def rb_null;      RubyValue.null; end
def rb_list(*xs); RubyValue.list(xs); end
def rb_map(h);    RubyValue.from(h); end

def rs_int(n);    RustPort::V.new(:int, n); end
def rs_str(s);    RustPort::V.new(:str, s); end
def rs_bool(b);   RustPort::V.new(:bool, b); end
def rs_null;      RustPort::V.new(:null, nil); end
def rs_list(*xs); RustPort::V.new(:list, xs); end
def rs_map(h);    RustPort::V.new(:map, h); end

# --------------------------------------------------------------------
# Test pairs — each entry is [label, ruby_pair, rust_pair]
# --------------------------------------------------------------------

CASES = [
  # --- PR #262 regression baseline (should now agree) ---
  ["Null == Str(\"\") [PR #262 regression]", [rb_null, rb_str("")], [rs_null, rs_str("")]],

  # --- to_display fallback misfires ---
  ["Null == Int(0)",                    [rb_null, rb_int(0)],        [rs_null, rs_int(0)]],
  ["Null == Str(\"0\")",                [rb_null, rb_str("0")],      [rs_null, rs_str("0")]],
  ["Null == Bool(false)",               [rb_null, rb_bool(false)],   [rs_null, rs_bool(false)]],
  ["Null == Null",                      [rb_null, rb_null],          [rs_null, rs_null]],
  ["Null == empty List",                [rb_null, rb_list],          [rs_null, rs_list]],
  ["Null == empty Map",                 [rb_null, rb_map({})],       [rs_null, rs_map({})]],
  ["Null == Str(\"null\")",             [rb_null, rb_str("null")],   [rs_null, rs_str("null")]],

  # --- numeric coercion edges ---
  ["Int(0) == Str(\"0\")",              [rb_int(0), rb_str("0")],       [rs_int(0), rs_str("0")]],
  ["Int(1) == Str(\"1.0\")",            [rb_int(1), rb_str("1.0")],     [rs_int(1), rs_str("1.0")]],
  ["Int(1) == Str(\"1.5\")",            [rb_int(1), rb_str("1.5")],     [rs_int(1), rs_str("1.5")]],
  ["Int(0) == Bool(false)",             [rb_int(0), rb_bool(false)],    [rs_int(0), rs_bool(false)]],
  ["Int(1) == Bool(true)",              [rb_int(1), rb_bool(true)],     [rs_int(1), rs_bool(true)]],
  ["Str(\"1\") == Bool(true)",          [rb_str("1"), rb_bool(true)],   [rs_str("1"), rs_bool(true)]],
  ["Str(\"true\") == Bool(true)",       [rb_str("true"), rb_bool(true)],[rs_str("true"), rs_bool(true)]],
  ["Str(\" 1 \") == Int(1) (whitespace)", [rb_str(" 1 "), rb_int(1)],   [rs_str(" 1 "), rs_int(1)]],
  ["Str(\"1e3\") == Int(1000)",         [rb_str("1e3"), rb_int(1000)],  [rs_str("1e3"), rs_int(1000)]],

  # --- boolean / truthy ---
  ["Bool(false) == Int(0)",             [rb_bool(false), rb_int(0)],    [rs_bool(false), rs_int(0)]],
  ["Bool(false) == Null",               [rb_bool(false), rb_null],      [rs_bool(false), rs_null]],
  ["Bool(false) == Str(\"false\")",     [rb_bool(false), rb_str("false")], [rs_bool(false), rs_str("false")]],
  ["Bool(true) == Str(\"true\")",       [rb_bool(true), rb_str("true")],[rs_bool(true), rs_str("true")]],
  ["Bool(true) == Str(\"TRUE\")",       [rb_bool(true), rb_str("TRUE")],[rs_bool(true), rs_str("TRUE")]],

  # --- string case sensitivity ---
  ["Str(\"foo\") == Str(\"FOO\")",      [rb_str("foo"), rb_str("FOO")], [rs_str("foo"), rs_str("FOO")]],
  ["Str(\"\") == Str(\"\")",            [rb_str(""), rb_str("")],       [rs_str(""), rs_str("")]],
  ["Str(\"abc\") == Str(\"abc\")",      [rb_str("abc"), rb_str("abc")], [rs_str("abc"), rs_str("abc")]],

  # --- list comparison ---
  ["[1,2] == [1,2]",                    [rb_list(rb_int(1), rb_int(2)), rb_list(rb_int(1), rb_int(2))],
                                        [rs_list(rs_int(1), rs_int(2)), rs_list(rs_int(1), rs_int(2))]],
  ["[1,2] == [2,1] (order)",            [rb_list(rb_int(1), rb_int(2)), rb_list(rb_int(2), rb_int(1))],
                                        [rs_list(rs_int(1), rs_int(2)), rs_list(rs_int(2), rs_int(1))]],
  ["[1,2] == [3,4] (same length, diff)", [rb_list(rb_int(1), rb_int(2)), rb_list(rb_int(3), rb_int(4))],
                                        [rs_list(rs_int(1), rs_int(2)), rs_list(rs_int(3), rs_int(4))]],
  ["[] == []",                          [rb_list, rb_list],             [rs_list, rs_list]],
  ["[] == Str(\"[]\")",                 [rb_list, rb_str("[]")],        [rs_list, rs_str("[]")]],
  ["[] == Str(\"[0 items]\")",          [rb_list, rb_str("[0 items]")], [rs_list, rs_str("[0 items]")]],

  # --- map comparison ---
  ["{a:1} == {a:1}",                    [rb_map({"a" => 1}), rb_map({"a" => 1})],
                                        [rs_map({"a" => rs_int(1)}), rs_map({"a" => rs_int(1)})]],
  ["{a:1} == {b:1} (same size)",        [rb_map({"a" => 1}), rb_map({"b" => 1})],
                                        [rs_map({"a" => rs_int(1)}), rs_map({"b" => rs_int(1)})]],
  ["{a:1,b:2} == {b:2,a:1} (order)",    [rb_map({"a" => 1, "b" => 2}), rb_map({"b" => 2, "a" => 1})],
                                        [rs_map({"a" => rs_int(1), "b" => rs_int(2)}),
                                         rs_map({"b" => rs_int(2), "a" => rs_int(1)})]],
  ["{} == Str(\"{0 fields}\")",         [rb_map({}), rb_str("{0 fields}")],
                                        [rs_map({}), rs_str("{0 fields}")]],
  ["{} == Str(\"{}\")",                 [rb_map({}), rb_str("{}")],
                                        [rs_map({}), rs_str("{}")]],

  # --- float / whole-number formatting ---
  # NB: Ruby Value.from(Float) stores as :str with #to_s. Rust has no
  # Float variant. So Ruby 1.0 → Str("1.0"); 1 → Int(1).
  ["Float 1.0 (Ruby Str) == Int(1)",    [RubyValue.from(1.0), rb_int(1)], [rs_str("1.0"), rs_int(1)]],

  # --- special values in strings that collide with display forms ---
  ["Int(2) == Str(\"[2 items]\")",      [rb_int(2), rb_str("[2 items]")], [rs_int(2), rs_str("[2 items]")]],
  ["[a,b] == [c,d] (content differs, length same)",
     [rb_list(rb_str("a"), rb_str("b")), rb_list(rb_str("c"), rb_str("d"))],
     [rs_list(rs_str("a"), rs_str("b")), rs_list(rs_str("c"), rs_str("d"))]],
]

# --------------------------------------------------------------------
# Run
# --------------------------------------------------------------------

rows = CASES.map do |label, rb_pair, rs_pair|
  a_rb, b_rb = rb_pair
  a_rs, b_rs = rs_pair
  ruby_result = RubyValue.equal?(a_rb, b_rb)
  rust_result = RustPort.equal?(a_rs, b_rs)
  agree = (ruby_result == rust_result)
  { label: label, ruby: ruby_result, rust: rust_result, agree: agree }
end

disagreements = rows.reject { |r| r[:agree] }

puts "## Test cases\n\n"
puts "| # | Case | Ruby | Rust | Agrees |"
puts "|---|------|------|------|--------|"
rows.each_with_index do |r, i|
  marker = r[:agree] ? "yes" : "**NO**"
  puts "| #{i + 1} | #{r[:label]} | `#{r[:ruby]}` | `#{r[:rust]}` | #{marker} |"
end

puts "\n## Summary\n"
puts "Total cases:    #{rows.length}"
puts "Agreements:     #{rows.length - disagreements.length}"
puts "Disagreements:  #{disagreements.length}"
puts
puts "## Disagreements only\n"
disagreements.each do |r|
  puts "- #{r[:label]} — Ruby=#{r[:ruby]}, Rust=#{r[:rust]}"
end

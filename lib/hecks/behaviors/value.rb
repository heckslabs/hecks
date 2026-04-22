# Hecks::Behaviors::Value
#
# Typed dynamic value used by the in-memory behaviors runtime.
# Mirrors hecks_life/src/runtime/mod.rs `Value` enum: Int, Bool, Str,
# Null, List, Map. Comparable across types via numeric coercion so
# `Int(0) == Str("0")` and `Bool(true) == Str("true")`.
#
# The runner keeps Value as the canonical wire form between attrs,
# state, and assertions. Display form (`#to_display`) is what the
# `expect` map compares against — both Ruby and Rust runners produce
# identical strings here.
#
#   v = Value.from(42)        # => Value::Int
#   v.to_display              # => "42"
#   v.numeric                 # => 42.0
#   Value.equal?(a, b)        # loose equality with coercion
module Hecks
  module Behaviors
    class Value
      attr_reader :kind, :raw

      def initialize(kind, raw)
        @kind = kind
        @raw  = raw
      end

      # Build a Value from any Ruby object.
      def self.from(obj)
        case obj
        when Value      then obj
        when Integer    then new(:int,  obj)
        when Float      then new(:str,  format_float(obj))
        when TrueClass  then new(:bool, true)
        when FalseClass then new(:bool, false)
        when nil        then new(:null, nil)
        when Array      then new(:list, obj.map { |x| from(x) })
        when Hash       then new(:map,  obj.transform_values { |v| from(v) })
        else
          # Strings + symbols + everything else: coerce to display form.
          str = obj.to_s
          if (n = Integer(str, exception: false))
            new(:int, n)
          elsif str == "true"
            new(:bool, true)
          elsif str == "false"
            new(:bool, false)
          else
            new(:str, str)
          end
        end
      end

      def self.format_float(f)
        # Preserve `.0` for whole-valued floats — Rust's Display for f64
        # prints 1.0 as "1" but the runner stringifies floats from the
        # source DSL via the parser which keeps the trailing zero.
        # Match the test corpus: keep `.0` so `Float :amount, 1.0` stays
        # `"1.0"` in expects.
        s = f.to_s
        s
      end

      def self.null;  new(:null, nil); end
      def self.list(items = []); new(:list, items.map { |x| from(x) }); end

      def to_display
        case @kind
        when :int  then @raw.to_s
        when :bool then @raw ? "true" : "false"
        when :null then ""
        when :str  then @raw
        when :list then "[#{@raw.map(&:to_display).join(", ")}]"
        when :map  then "{#{@raw.map { |k, v| "#{k}: #{v.to_display}" }.join(", ")}}"
        end
      end

      def numeric
        case @kind
        when :int  then @raw.to_f
        when :bool then @raw ? 1.0 : 0.0
        when :null then 0.0
        when :str  then Float(@raw, exception: false)
        else nil
        end
      end

      def list?; @kind == :list; end
      def list_size; list? ? @raw.size : 0; end
      def str_size;  @kind == :str ? @raw.length : 0; end

      # Structural equality on the Value ADT. Two Values are `==` when
      # their kind matches and their raw payload matches; for :list and
      # :map this recurses (Array#== and Hash#== call Value#== on inner
      # elements). Without this, `raw == raw` on nested lists/maps fell
      # through to object identity and leaked into `Value.equal?` — the
      # latent bug flagged as class 5 in PR #264's audit.
      def ==(other)
        return false unless other.is_a?(Value)
        return false unless @kind == other.kind
        @raw == other.raw
      end
      alias eql? ==

      def hash
        [@kind, @raw].hash
      end

      # Loose equality: Bool(true)==Str("true"), Int(42)==Str("42"),
      # numeric coercion handles Int<->Str("0")<->Null comparisons.
      # A Null on either side compares via numeric ONLY — it must NOT
      # fall through to the display-form tiebreaker, where Null's ""
      # would match Str("") and make `before_snapshot != ""` silently
      # pass on uninitialized state. Mirrors hecks_life's
      # `values_equal`, where `Display(Null) = "null"` keeps the same
      # fallback false and the cascade (policy→command→given) advances.
      # A :list on either side likewise short-circuits: Rust's
      # `Display for Value::List` is `"[N items]"` (count-only) which
      # collides for same-size lists, and Ruby's `"[1, 2]"` collides
      # with `Str("[1, 2]")`. Structural equality via the new
      # `Value#==` already ran above; when it fails we should NOT let
      # display form cast a tie. Audit cases 27, 28, 30, 31, 39.
      def self.equal?(a, b)
        return true if a.kind == b.kind && a.raw == b.raw
        an = a.numeric
        bn = b.numeric
        return an == bn if an && bn
        return false if a.kind == :null || b.kind == :null
        return false if a.kind == :list || b.kind == :list
        a.to_display == b.to_display
      end

      def self.lt?(a, b)
        return a.raw < b.raw if a.kind == :int && b.kind == :int
        an = a.numeric; bn = b.numeric
        return an < bn if an && bn
        false
      end
    end
  end
end

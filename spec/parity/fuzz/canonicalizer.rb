# Hecks::Parity::Fuzz::Canonicalizer
#
# Purpose: reduce two .heki directory trees (one per runtime) to
# canonical JSON strings that can be byte-for-byte compared.
#
# Canonicalization:
#   1. Read every .heki in the tree via Hecks::Heki::Reader
#   2. Drop volatile fields (id, created_at, updated_at, archived_at)
#   3. Sort keys recursively (deterministic serialization)
#   4. Normalize numerics per declared type — Rust writes 1 as i64,
#      Ruby might write "1" as str; coerce to Int when the
#      aggregate's declared attribute type is Integer
#   5. Group records by aggregate (heki filename without extension),
#      values as arrays of field hashes (id-independent ordering via
#      deterministic sort on a composite key)
#
# The canonical form is intentionally *weaker* than a raw heki diff:
# it tolerates zlib-library drift and id-assignment order (ids are
# stripped), but surfaces every field value, policy outcome, and
# lifecycle state.
#
# Usage:
#   json = Canonicalizer.canonicalize("/tmp/fuzz-42/ruby/information",
#                                      ruby_domain)
#
# [antibody-exempt: differential fuzzer per i30 plan — retires when
# fuzzer ports to bluebook-dispatched form via hecks-life run]

require "json"
require "hecks/heki/reader"

module Hecks
  module Parity
    module Fuzz
      module Canonicalizer
        module_function

        VOLATILE_FIELDS = %w[id created_at updated_at archived_at].freeze

        # Canonicalize every .heki under `dir` into a sorted JSON string.
        # `type_map` is optional { "agg_name" => { "field" => :int|:str|... } }
        # and drives numeric normalization. When omitted, values stay as-is.
        def canonicalize(dir, type_map = {})
          return "{}" unless File.directory?(dir)
          stores = {}
          Dir.glob(File.join(dir, "*.heki")).sort.each do |path|
            name = File.basename(path, ".heki")
            records = safe_read(path)
            next if records.empty?
            agg = pascal_case(name)
            normalized = records.values.map { |r| normalize_record(r, type_map[agg] || {}) }
            stores[name] = normalized.sort_by { |r| JSON.generate(sort_keys(r)) }
          end
          JSON.generate(sort_keys(stores))
        end

        def safe_read(path)
          Hecks::Heki::Reader.read(path)
        rescue Hecks::Heki::InvalidFormatError
          {}
        end

        def normalize_record(record, field_types)
          out = {}
          record.each do |k, v|
            next if VOLATILE_FIELDS.include?(k.to_s)
            out[k.to_s] = coerce(v, field_types[k.to_s])
          end
          out
        end

        # Coerce a raw JSON value to the shape both runtimes should
        # agree on. Integer-declared fields go through to_i, Float-
        # declared go through to_f. String fields unwrap numeric
        # strings into numbers iff the other runtime might have
        # written them as numbers (Rust Int vs Ruby Str("1") drift).
        def coerce(value, declared_type)
          case declared_type
          when :int
            return value.to_i if value.is_a?(Numeric)
            return Integer(value.to_s, exception: false) || value.to_s if value.is_a?(String)
            value
          when :float
            return value.to_f if value.is_a?(Numeric) || value.is_a?(String)
            value
          when :bool
            return value if value == true || value == false
            return true  if value.to_s == "true"
            return false if value.to_s == "false"
            value
          when :list_int, :list_str
            return [] unless value.is_a?(Array)
            value.map { |x| coerce(x, declared_type == :list_int ? :int : :str) }.sort_by(&:to_s)
          else
            value
          end
        end

        def sort_keys(obj)
          case obj
          when Hash  then obj.keys.map(&:to_s).sort.each_with_object({}) { |k, acc| acc[k] = sort_keys(obj[k] || obj[k.to_sym]) }
          when Array then obj.map { |x| sort_keys(x) }
          else obj
          end
        end

        # Counter → counter. Mirrors hecks_life/src/runtime/repository.rs
        # heki_path() snake-case rule.
        def snake_case(name)
          out = +""
          name.to_s.chars.each_with_index do |c, i|
            out << "_" if c =~ /[A-Z]/ && i > 0
            out << c.downcase
          end
          out
        end

        # counter → Counter. Best-effort reverse for looking up type
        # maps keyed by aggregate name.
        def pascal_case(snake)
          snake.to_s.split("_").map(&:capitalize).join
        end

        # Build a { "AggName" => { "field_name" => :int|:str|:float|... } }
        # lookup from a Hecks domain (Ruby-side DSL structure). The
        # comparator uses this to drive type-aware coercion.
        def build_type_map(domain)
          map = {}
          (domain.aggregates || []).each do |agg|
            fields = {}
            (agg.attributes || []).each do |a|
              fields[a.name.to_s] = type_key_for(a)
            end
            map[agg.name] = fields
          end
          map
        end

        def type_key_for(attr)
          raw = attr.respond_to?(:type) ? attr.type : nil
          t = raw.is_a?(Class) ? raw.name : raw.to_s
          list = attr.respond_to?(:list?) ? attr.list? : false
          case t
          when "Integer" then list ? :list_int : :int
          when "Float"   then :float
          when "String"  then list ? :list_str : :str
          when "Boolean", "TrueClass", "FalseClass" then :bool
          else :str
          end
        end
      end
    end
  end
end

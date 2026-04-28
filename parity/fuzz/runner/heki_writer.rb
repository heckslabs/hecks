# Hecks::Parity::Fuzz::Runner::HekiWriter
#
# Purpose: dump a live Hecks::Behaviors::BehaviorRuntime's
# repositories to `.heki` files in the same binary envelope the
# Rust runtime produces ("HEKI" magic + u32 big-endian record count
# + zlib-compressed JSON of { id => record }). That lets the
# comparator read both trees through one reader and compare on
# equal footing.
#
# Filename mapping mirrors hecks_life/src/runtime/repository.rs's
# heki_path(): "Counter" → "counter.heki", "Agg1" → "agg1.heki".
#
# [antibody-exempt: differential fuzzer per i30 plan — retires when
# fuzzer ports to bluebook-dispatched form via hecks-life run]

require "json"
require "zlib"
require "fileutils"

module Hecks
  module Parity
    module Fuzz
      module Runner
        module HekiWriter
          module_function

          def write_all(rt, info_dir)
            FileUtils.mkdir_p(info_dir)
            rt.repositories.each do |agg_name, repo|
              next if repo.empty?
              path = File.join(info_dir, "#{snake_case(agg_name)}.heki")
              store = {}
              repo.each do |id, state|
                rec = { "id" => id.to_s }
                state.fields.each { |k, v| rec[k.to_s] = value_to_json(v) }
                store[id.to_s] = rec
              end
              write_heki(path, store)
            end
          end

          def write_heki(path, store)
            json = JSON.generate(store)
            compressed = Zlib.deflate(json, Zlib::BEST_COMPRESSION)
            File.binwrite(path, "HEKI".b + [store.size].pack("N") + compressed)
          end

          def snake_case(name)
            out = +""
            name.to_s.chars.each_with_index do |c, i|
              out << "_" if c =~ /[A-Z]/ && i > 0
              out << c.downcase
            end
            out
          end

          # Translate a Hecks::Behaviors::Value to a JSON-writable
          # primitive. Mirrors hecks_life/src/runtime/repository.rs
          # to_json(): Int → i64, Bool → bool, Str → string, Null →
          # null, List → array, Map → object.
          def value_to_json(value)
            case value.kind
            when :int  then value.raw
            when :bool then value.raw
            when :str
              raw = value.raw
              # Ruby runtime stores Float-typed fields as :str with the
              # formatted numeric ("2.5"); the Rust side often stores
              # these as f64 in JSON. Canonicalizer normalizes on read,
              # so we keep the string-of-number here rather than pre-
              # coerce — that way only declared-Float fields coerce,
              # not every coincidentally-numeric string.
              raw
            when :null then nil
            when :list then value.raw.map { |v| value_to_json(v) }
            when :map  then value.raw.transform_values { |v| value_to_json(v) }
            else value.raw
            end
          end
        end
      end
    end
  end
end

# lib/hecks_specializer/meta_ruby_script.rb
#
# Hecks::Specializer::MetaRubyScript — Phase C PC-3.
#
# Third meta-specializer. Regenerates a top-level Ruby script from a
# single RubyScript fixture row. Covers the driver script itself
# (bin/specialize) — first retirement under bin/.
#
# Emission pipeline (verbatim concatenation):
#
#   1. shebang line + "\n" — skipped entirely if shebang is empty
#   2. doc_snippet — read raw (already ends with "\n")
#   3. "\n" — blank line separator
#   4. requires_block_snippet — read raw (already ends with "\n")
#   5. "\n" — blank line separator
#   6. body_snippet — read raw (already ends with "\n")
#
# Everything other than the shebang is snippet-driven, so the shape
# stays honest about script bodies being author-verbatim. What the
# meta-specializer contributes is the skeleton (shebang + inter-
# section blank lines) and a data-driven choice of which row to emit.
#
# Subclasses override `self.target_row_name` to pick which RubyScript
# row to emit for. Default (nil) picks the first row — kept simple
# for the PC-3 pilot, which ships with a single row (Specialize).
#
# `executable` is currently metadata only — the CLI prints to stdout
# and `--output` writes text. A future driver pass may chmod +x on
# write. The specializer's own output stays deterministic text.

module Hecks
  module Specializer
    class MetaRubyScript
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/ruby_script_shape/fixtures/ruby_script_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("bin/specialize")

      # Which RubyScript fixture row to emit for. Subclasses override
      # to pick a different row. Default (nil) picks the first row.
      def self.target_row_name
        nil
      end

      def emit
        row = pick_row
        [
          emit_shebang(row),
          emit_doc(row),
          emit_requires(row),
          emit_body(row),
        ].join
      end

      private

      def pick_row
        rows = by_aggregate("RubyScript")
        name = self.class.target_row_name
        row = name ? rows.find { |r| r["attrs"]["name"] == name } : rows.first
        raise "no RubyScript row matching #{name.inspect}" unless row
        row
      end

      # Shebang line followed by "\n". Empty string (no shebang) skips
      # the whole line — used for plain `.rb` outputs with no shebang.
      def emit_shebang(row)
        shebang = row["attrs"]["shebang"]
        return "" if shebang.nil? || shebang.empty?
        "#{shebang}\n"
      end

      # Doc block — read verbatim. Snippet already ends with "\n".
      # Append one more "\n" to insert the blank line that separates
      # doc from requires.
      def emit_doc(row)
        File.read(REPO_ROOT.join(row["attrs"]["doc_snippet"])) + "\n"
      end

      # Requires block — read verbatim. Snippet already ends with "\n".
      # Append one more "\n" to insert the blank line that separates
      # requires from body.
      def emit_requires(row)
        File.read(REPO_ROOT.join(row["attrs"]["requires_block_snippet"])) + "\n"
      end

      # Imperative body — read verbatim. Final section; snippet's own
      # trailing "\n" is the file's trailing newline.
      def emit_body(row)
        File.read(REPO_ROOT.join(row["attrs"]["body_snippet"]))
      end
    end

    register :meta_ruby_script, MetaRubyScript
  end
end

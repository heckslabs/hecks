# lib/hecks_specializer/fixtures_parser.rb
#
# Hecks::Specializer::FixturesParser — emits hecks_life/src/fixtures_parser.rs
# byte-identical from fixtures_parser_shape.fixtures.
#
# Fifth Phase B parser/validator/dump retirement; closes the Phase B
# Rust retirement arc (i51). The most hostile target so far — five
# subsystems (expand_ruby_escapes, matching_close_brace,
# extract_schema_kwarg, extract_string_escape_aware, first_top_level_comma)
# plus 3 simpler helpers and a 115-line in-file test block all escape-
# hatched as verbatim .rs.frag snippets.
#
# Shape inherits hecksagon_parser_shape's 3-aggregate layout. Extensions:
#
#   LineParser.parse_body_snippet  — verbatim parse() fn body; the
#     if/else-if chain + state prelude don't fit hecksagon's
#     continue-per-branch template.
#   LineParser.test_block_snippet  — verbatim `#[cfg(test)]` block.
#   ParserHelper.position          — before_root | after_root; two
#     helpers live above parse() in the current source.
#   ParserHelper.doc_snippet       — path to a //-doc snippet; used
#     instead of the inline doc_comment for longer docs (up to 20
#     lines for expand_ruby_escapes).
#
# [antibody-exempt: lib/hecks_specializer/fixtures_parser.rb — generator, not generated]

module Hecks
  module Specializer
    class FixturesParser
      include Target

      SHAPE     = REPO_ROOT.join("hecks_conception/capabilities/fixtures_parser_shape/fixtures/fixtures_parser_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/fixtures_parser.rs")

      def emit
        parser  = by_aggregate("LineParser").first
        helpers = by_aggregate("ParserHelper")
                    .select { |h| h["attrs"]["parser"] == parser["attrs"]["module"] }

        before = helpers
                   .select { |h| (h["attrs"]["position"] || "after_root") == "before_root" }
                   .sort_by { |h| h["attrs"]["order"].to_i }
        after  = helpers
                   .select { |h| (h["attrs"]["position"] || "after_root") == "after_root" }
                   .sort_by { |h| h["attrs"]["order"].to_i }

        parts = []
        parts << emit_header(parser)
        parts << emit_imports(parser)
        before.each { |h| parts << emit_helper(h) }
        parts << emit_parse(parser)
        after.each  { |h| parts << emit_helper(h) }
        parts << emit_test_block(parser)
        parts.join
      end

      private

      def emit_header(parser)
        read_raw(parser["attrs"]["doc_snippet"]) + "\n"
      end

      def emit_imports(parser)
        lines = parser["attrs"]["imports"].split("\n").reject(&:empty?)
        lines.map { |imp| "use #{imp};" }.join("\n") + "\n\n"
      end

      def emit_parse(parser)
        sig  = parser["attrs"]["root_signature"]
        body = read_raw(parser["attrs"]["parse_body_snippet"])
        "#{sig} {\n#{body}}\n\n"
      end

      def emit_helper(helper)
        a   = helper["attrs"]
        doc = helper_doc(a)
        body = read_raw(a["body_snippet"])
        "#{doc}#{a["signature"]} {\n#{body}}\n\n"
      end

      def helper_doc(attrs)
        snippet = attrs["doc_snippet"].to_s
        return read_raw(snippet) unless snippet.empty?
        inline = attrs["doc_comment"].to_s
        return "" if inline.empty?
        inline + "\n"
      end

      def emit_test_block(parser)
        snippet = parser["attrs"]["test_block_snippet"].to_s
        return "" if snippet.empty?
        # The test block snippet already ends with its closing `}\n`.
        # No trailing blank line — the file ends right after.
        read_raw(snippet)
      end

      # Override the shared read_snippet_body helper. Several fixtures_parser
      # helper bodies legitimately start with //-comments (e.g.,
      # extract_schema_kwarg's body opens with `// Find the first top-level
      # comma …`), which the generic Hecks::Specializer.read_snippet_body
      # would strip as a leading-comment header. We instead use bare
      # File.read; snippets are headerless (the filename documents them).
      def read_raw(rel_path)
        abs = REPO_ROOT.join(rel_path)
        raise "snippet missing: #{abs}" unless File.exist?(abs)
        File.read(abs)
      end
    end

    register :fixtures_parser, FixturesParser
  end
end

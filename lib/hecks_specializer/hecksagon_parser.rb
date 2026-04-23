# lib/hecks_specializer/hecksagon_parser.rb
#
# Hecks::Specializer::HecksagonParser — emits hecks_life/src/hecksagon_parser.rs
# byte-identical from hecksagon_parser_shape.fixtures.
#
# Third parser retirement after validator.rs and dump.rs (i51 Phase B).
# Establishes the parser-shape template for behaviors_parser +
# fixtures_parser follow-ups. Shape factors the 189-LoC file into:
#
#   LineParser    (1 row) — outer module contract
#   LineDispatch  (N rows) — one per line-leading token handled
#   ParserHelper  (N rows) — private helpers emitted verbatim
#
# The parse() loop is templated: each LineDispatch row becomes one
# `if line.starts_with(...)` block. Per-character automaton bodies
# (join_adapter_lines) and kwarg dispatch tables (parse_shell_adapter)
# are emitted verbatim via body_snippets — they don't factor into
# clean templates.

module Hecks
  module Specializer
    class HecksagonParser
      include Target

      SHAPE     = REPO_ROOT.join("hecks_conception/capabilities/hecksagon_parser_shape/fixtures/hecksagon_parser_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/hecksagon_parser.rs")

      def emit
        parser     = by_aggregate("LineParser").first
        dispatches = by_aggregate("LineDispatch")
                       .select { |d| d["attrs"]["parser"] == parser["attrs"]["module"] }
                       .sort_by { |d| d["attrs"]["order"].to_i }
        helpers    = by_aggregate("ParserHelper")
                       .select { |h| h["attrs"]["parser"] == parser["attrs"]["module"] }
                       .sort_by { |h| h["attrs"]["order"].to_i }

        parts = [
          emit_header(parser),
          emit_imports(parser),
          emit_detector(parser),
          emit_parse(parser, dispatches),
        ]
        helpers.each_with_index do |h, i|
          parts << emit_helper(h, trailing_blank: i < helpers.size - 1)
        end
        parts.join
      end

      private

      def emit_header(parser)
        path = REPO_ROOT.join(parser["attrs"]["doc_snippet"])
        File.read(path) + "\n"
      end

      def emit_imports(parser)
        lines = parser["attrs"]["imports"].split("\n").reject(&:empty?)
        lines.map { |imp| "use #{imp};" }.join("\n") + "\n\n"
      end

      def emit_detector(parser)
        a = parser["attrs"]
        <<~RS
          /// Lowest-cost source detection. Skips leading blanks and `#` comments
          /// and checks the first non-empty line.
          pub fn #{a["detector_fn_name"]}(source: &str) -> bool {
              for line in source.lines() {
                  let t = line.trim();
                  if t.is_empty() || t.starts_with('#') { continue; }
                  return t.starts_with("#{a["detector_keyword"]}");
              }
              false
          }

        RS
      end

      def emit_parse(parser, dispatches)
        sig = parser["attrs"]["root_signature"]
        # Separator between dispatch blocks: a blank line (matching the
        # hand-written spacing). The blocks themselves are indented 8
        # spaces (inside `while`).
        blocks = dispatches.map { |d| emit_dispatch_block(d) }.join("\n")
        <<~RS
          #{sig} {
              let mut hex = Hecksagon::default();
              let source = crate::parser::strip_shebang(source);
              let raw: Vec<&str> = source.lines().collect();

              let mut i = 0;
              while i < raw.len() {
                  let line = raw[i].trim();

          #{blocks}
                  i += 1;
              }

              hex
          }

        RS
      end

      # Each dispatch block is 8-space indented:
      #
      #         if line.starts_with("…") {
      #             <body>
      #             continue;
      #         }
      def emit_dispatch_block(dispatch)
        a = dispatch["attrs"]
        condition = dispatch_condition(a["starts_with"])
        body_lines = dispatch_body_lines(a)
        lines = []
        lines << "        if #{condition} {"
        body_lines.each { |l| lines << "            #{l}" }
        lines << "            continue;"
        lines << "        }"
        lines.join("\n") + "\n"
      end

      def dispatch_condition(starts_with)
        prefixes = starts_with.split(",")
        prefixes.map { |p| %(line.starts_with("#{p}")) }.join(" || ")
      end

      # Each element is an inner-body line without the 12-space prefix
      # (added by emit_dispatch_block).
      def dispatch_body_lines(attrs)
        case attrs["handler_kind"]
        when "capture_quoted_into"
          [
            %(if let Some(n) = between_quotes(line) { hex.#{attrs["target_field"]} = n; }),
            "i += 1;",
          ]
        when "push_quoted_onto"
          [
            %(if let Some(n) = between_quotes(line) { hex.#{attrs["target_field"]}.push(n); }),
            "i += 1;",
          ]
        when "multiline_block"
          [
            "let (gate, consumed) = #{attrs["helper_fn"]}(&raw[i..]);",
            "if let Some(g) = gate { hex.#{attrs["target_field"]}.push(g); }",
            "i += consumed;",
          ]
        when "multiline_adapter"
          [
            "let (joined, consumed) = join_adapter_lines(&raw[i..]);",
            "#{attrs["helper_fn"]}(&joined, &mut hex);",
            "i += consumed;",
          ]
        else
          raise "unknown handler_kind: #{attrs["handler_kind"]}"
        end
      end

      def emit_helper(helper, trailing_blank: false)
        a = helper["attrs"]
        body = read_snippet_body(REPO_ROOT.join(a["body_snippet"]))
        doc = a["doc_comment"].to_s
        doc_block = doc.empty? ? "" : doc + "\n"
        core = "#{doc_block}#{a["signature"]} {\n#{body}}\n"
        trailing_blank ? core + "\n" : core
      end
    end

    register :hecksagon_parser, HecksagonParser
  end
end

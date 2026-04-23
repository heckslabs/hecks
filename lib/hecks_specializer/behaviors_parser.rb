# lib/hecks_specializer/behaviors_parser.rb
#
# Hecks::Specializer::BehaviorsParser — emits hecks_life/src/behaviors_parser.rs
# byte-identical from behaviors_parser_shape.fixtures.
#
# Fourth parser retirement (i51 Phase B) after validator.rs, dump.rs, and
# hecksagon_parser.rs. Reuses the hecksagon parser-shape 3-aggregate pattern
# (LineParser / LineDispatch / ParserHelper) with three extensions:
#
#   loop_style = "else_if"           — if/else-if chain (trivial branches
#                                       fall through; multiline branch
#                                       ends with an explicit continue).
#   new handler_kinds                — capture_quoted_into_option,
#                                       push_all_quoted_onto,
#                                       multiline_block_direct.
#   detector_position/tests_snippet  — detector emitted after helpers;
#                                       inline #[cfg(test)] module shipped
#                                       as a verbatim snippet on LineParser.
#
# Keeps the LineParser schema extensible without touching the hecksagon
# specializer (per plan: copy the pattern, stay standalone; extract a
# common LineParserBase only after the third parser lands).
#
# [antibody-exempt: lib/hecks_specializer/behaviors_parser.rb — generator, not generated]

module Hecks
  module Specializer
    class BehaviorsParser
      include Target

      SHAPE     = REPO_ROOT.join("hecks_conception/capabilities/behaviors_parser_shape/fixtures/behaviors_parser_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/behaviors_parser.rs")

      def emit
        parser     = by_aggregate("LineParser").first
        dispatches = by_aggregate("LineDispatch")
                       .select { |d| d["attrs"]["parser"] == parser["attrs"]["module"] }
                       .sort_by { |d| d["attrs"]["order"].to_i }
        helpers    = by_aggregate("ParserHelper")
                       .select { |h| h["attrs"]["parser"] == parser["attrs"]["module"] }
                       .sort_by { |h| h["attrs"]["order"].to_i }

        parts = [emit_header(parser), emit_imports(parser), emit_parse(parser, dispatches)]
        helpers.each { |h| parts << "\n" << emit_helper(h) }
        parts << "\n" << emit_detector(parser)
        tests = parser["attrs"]["tests_snippet"].to_s
        parts << "\n" << read_snippet_body(REPO_ROOT.join(tests)) unless tests.empty?
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
          /// Returns true if the source's first non-blank, non-comment line is the
          /// `#{a["detector_keyword"]}` keyword. Used by callers to dispatch to this parser
          /// instead of the regular bluebook parser.
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
        a = parser["attrs"]
        init = read_snippet_body(REPO_ROOT.join(a["state_init_snippet"]))
        loop_var = a["loop_var_name"]
        state_var = a["state_var"]
        dispatch_block = emit_dispatch_chain(dispatches, state_var, loop_var)
        # Explicit line-by-line assembly — avoids heredoc dedent traps
        # when interpolating already-indented multi-line fragments.
        lines = []
        lines << "#{a["root_signature"]} {"
        lines << init.chomp
        lines << ""
        lines << "    while i < #{loop_var}.len() {"
        lines << "        let line = #{loop_var}[i].trim();"
        lines << ""
        lines << dispatch_block.chomp
        lines << "        i += 1;"
        lines << "    }"
        lines << ""
        lines << "    #{state_var}"
        lines << "}"
        lines.join("\n") + "\n"
      end

      # Emit the if/else-if chain (or if-continue chain, for extensibility).
      # Dispatches are already in emission order.
      def emit_dispatch_chain(dispatches, state_var, loop_var)
        lines = []
        dispatches.each_with_index do |d, idx|
          a = d["attrs"]
          keyword_form = if idx == 0 then "if " else "} else if " end
          lines << "        #{keyword_form}#{dispatch_condition(a)} {"
          dispatch_body_lines(a, state_var, loop_var).each { |l| lines << "            #{l}" }
          if idx == dispatches.size - 1
            lines << "        }"
          end
        end
        lines.join("\n") + "\n"
      end

      # Encode starts_with / word / word_or_equal match modes.
      def dispatch_condition(attrs)
        mode = attrs["match_mode"].to_s
        mode = "prefix" if mode.empty?
        keyword = attrs["match_keyword"]
        case mode
        when "prefix"
          # Commas in keyword → OR list of prefixes.
          keyword.split(",").map { |p| %(line.starts_with("#{p}")) }.join(" || ")
        when "word"
          %(line.starts_with("#{keyword} ") || line.starts_with("#{keyword}\\t"))
        when "word_or_equal"
          %(line.starts_with("#{keyword} ") || line.starts_with("#{keyword}\\t") || line == "#{keyword}")
        else
          raise "unknown match_mode: #{mode.inspect}"
        end
      end

      # Inner-body lines for one dispatch, without the 12-space prefix
      # (added by emit_dispatch_chain).
      def dispatch_body_lines(attrs, state_var, loop_var)
        quote_fn = attrs["quote_fn"].to_s
        variadic_fn = attrs["variadic_fn"].to_s
        field = attrs["target_field"].to_s
        helper = attrs["helper_fn"].to_s
        comment = attrs["body_comment"].to_s
        cvar = attrs["capture_var"].to_s
        cvar = "n" if cvar.empty?

        lines = []
        comment.split("\n").each { |c| lines << "// #{c}" } unless comment.empty?

        case attrs["handler_kind"]
        when "capture_quoted_into"
          lines << %(if let Some(#{cvar}) = #{quote_fn}(line) { #{state_var}.#{field} = #{cvar}; })
        when "capture_quoted_into_option"
          lines << %(if let Some(#{cvar}) = #{quote_fn}(line) { #{state_var}.#{field} = Some(#{cvar}); })
        when "push_quoted_onto"
          lines << %(if let Some(#{cvar}) = #{quote_fn}(line) { #{state_var}.#{field}.push(#{cvar}); })
        when "push_all_quoted_onto"
          lines << "for name in #{variadic_fn}(line) {"
          lines << "    #{state_var}.#{field}.push(name);"
          lines << "}"
        when "multiline_block_direct"
          lines << "let (test, consumed) = #{helper}(&#{loop_var}[i..]);"
          lines << "#{state_var}.#{field}.push(test);"
          lines << "i += consumed;"
          lines << "continue;"
        when "multiline_block"
          lines << "let (gate, consumed) = #{helper}(&#{loop_var}[i..]);"
          lines << "if let Some(g) = gate { #{state_var}.#{field}.push(g); }"
          lines << "i += consumed;"
          lines << "continue;"
        else
          raise "unknown handler_kind: #{attrs["handler_kind"].inspect}"
        end

        lines
      end

      def emit_helper(helper)
        a = helper["attrs"]
        body = read_snippet_body(REPO_ROOT.join(a["body_snippet"]))
        doc = a["doc_comment"].to_s
        doc_block = doc.empty? ? "" : doc + "\n"
        "#{doc_block}#{a["signature"]} {\n#{body}}\n"
      end
    end

    register :behaviors_parser, BehaviorsParser
  end
end

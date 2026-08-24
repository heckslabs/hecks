module RustProjection
  # THE LOADER/RENDERER for rust/src/exemplar/*.rs — real, `cargo
  # test`-checked Rust that stands in for what used to be hand-interpolated
  # strings scattered across this directory's emit_* functions. See the
  # exemplar-driven-codegen plan this was built from for the full design;
  # in short: every shape a generator emits is written ONCE, for real, as
  # a complete compiling Rust item in rust/src/exemplar/*.rs, fenced with
  # `// TMPL:<id> BEGIN` / `// TMPL:<id> END` comments. This module slices
  # those fences out and substitutes real domain names for the fixed
  # `Tmpl`/`tmpl_`/`TMPL_` placeholder vocabulary the exemplar uses
  # throughout — never a structural rewrite, only identifier-for-identifier
  # (or whole-literal-for-whole-literal) substitution, which is what lets a
  # substitution never produce invalid syntax: the exemplar was already
  # valid with the placeholder in that exact position.
  #
  # WHAT VARIES SHAPE TO SHAPE ISN'T INVENTED HERE, EITHER: `lib/hecks/
  # language/bluebook/shape.bluebook`'s own `ShapeField` already names, once
  # for the whole language, the axes a real attribute's shape can vary
  # along (`list`, `optional`, `pattern`, `admits`). The exemplar shapes
  # under rust/src/exemplar/{types,fielded,json,mutations}.rs branch on
  # exactly those same axes — each shape's own header says which
  # `ShapeField` attribute it's the Rust reading of, rather than
  # re-deriving the taxonomy independently.
  module Exemplar
    # ANY marker this vocabulary can produce — checked both ways: every
    # `subs` key a caller supplies must appear in the shape's raw text
    # (else the caller drifted from what the exemplar actually declares),
    # and after substitution NOTHING matching this pattern may remain
    # (else the caller forgot a placeholder, and literal `TmplType` text
    # would otherwise leak into real generated output). One regex covers
    # both identifier-shaped placeholders (`TmplType`, `tmpl_field`,
    # `TMPL_TABLE`) and literal-content placeholders (`"tmpl_prefix_text"`,
    # `["tmpl_member_a", "tmpl_member_b"]`) — every literal placeholder
    # this file ever writes embeds a `tmpl_`/`Tmpl`/`TMPL_` token
    # somewhere inside it for exactly this reason.
    LEFTOVER_PLACEHOLDER = /\b(?:Tmpl\w*|tmpl_\w*|TMPL_\w*)\b/

    DEFAULT_DIR = File.expand_path("../src/exemplar", __dir__)

    class DriftError < StandardError; end

    class << self
      # Overridable so specs can point this at a scratch fixture tree
      # (`reset!(dir: ...)`) without ever touching the real exemplar —
      # `compose`'s nested-slot behavior in particular needs a fixture
      # with a deliberately nested marker pair to exercise honestly.
      def dir
        @dir ||= DEFAULT_DIR
      end

      # `id` -> raw shape text (dedented, marker lines excluded). A shape
      # whose region contains a NESTED `// TMPL:<id>:<sub> BEGIN/END` pair
      # keeps a `<<TMPL_SLOT:<id>:<sub>>>` sentinel in its own text where
      # the nested region sat — see `compose`.
      def shapes
        @shapes ||= parse_all
      end

      # Fixed-arity rendering: `subs` is a Hash of marker-string =>
      # replacement-text. Every marker is a literal substring match (never
      # a regex) — deliberately: a placeholder like `["tmpl_member_a",
      # "tmpl_member_b"]` isn't identifier-shaped, and plain substring
      # replacement is exactly as safe as regex here BECAUSE this file
      # controls 100% of what markers exist in the exemplar. Longer
      # markers substitute first so one marker can never accidentally eat
      # a piece of another (`tmpl_field` vs a hypothetical
      # `tmpl_field_extra`, say).
      #
      # `gsub(marker, value)` — the two-arg form — is a trap here: Ruby
      # interprets backslash sequences (`\\`, `\1`, ...) INSIDE the
      # replacement string even when `marker` is a plain String, not a
      # Regexp. A pattern's `.inspect`ed source (`"^...\\.[^@ ]+$"`, a
      # real double backslash before the dot) silently collapsed to a
      # single backslash through this path — found live, diffing
      # generated output against the pre-exemplar checked-in files. The
      # block form never interprets its return value; every substitution
      # here uses it for exactly that reason.
      def render(shape_id, subs)
        text = raw(shape_id)

        subs.keys.sort_by { |k| -k.length }.each do |marker|
          raise DriftError, "Exemplar.render(#{shape_id.inspect}): marker #{marker.inspect} not found in shape text — " \
                             "exemplar and Ruby caller have drifted" unless text.include?(marker)

          value = subs[marker]
          text = text.gsub(marker) { value }
        end

        if (leftover = text.scan(LEFTOVER_PLACEHOLDER)).any?
          raise DriftError, "Exemplar.render(#{shape_id.inspect}): unrendered placeholder(s) #{leftover.uniq.inspect} — " \
                             "subs is missing a marker this shape actually contains"
        end

        text
      end

      # Variable-arity rendering: renders `shape_id` once per entry in
      # `subs_list`, joined by `join_with` — the mechanism a caller with
      # (say) one mutation line per `sets` reaches for, matching how
      # the ORIGINAL emit_* functions were already called once per
      # mutation/field/command by their own composite caller.
      def render_each(shape_id, subs_list, join_with: "\n")
        subs_list.map { |subs| render(shape_id, subs) }.join(join_with)
      end

      # General splice: `outer_id`'s own text may nest more than one
      # marker (a closed-set codec's `impl` block nests a `to_json` arm
      # slot AND a separate `from_json` arm slot, both inside the same
      # outer item) — `slots` is `field_id => already-rendered content`,
      # one entry per nested marker to fill. Each slot is reindented by
      # its OWN marker's position before splicing, independently, so two
      # slots at different depths in the same outer shape each come out
      # right. Outer placeholders substitute LAST, after every slot is
      # filled, so an outer marker can never accidentally match text that
      # came from an already-rendered slot.
      def assemble(outer_id, outer_subs, slots:)
        outer_text = raw(outer_id)

        slots.each do |field_id, content|
          slot = "<<TMPL_SLOT:#{field_id}>>"
          slot_line = outer_text.match(/^([ \t]*)#{Regexp.escape(slot)}$/)
          raise DriftError, "Exemplar.assemble(#{outer_id.inspect}): no nested slot for #{field_id.inspect} — " \
                             "expected a `// TMPL:#{field_id} BEGIN/END` region nested inside `// TMPL:#{outer_id} BEGIN/END`" unless slot_line

          # Reindent every line of the slot's content by the marker's OWN
          # indentation — the nested marker's position in the exemplar is
          # what says how deep a real field/arm line belongs, not
          # anything a caller passes in.
          indent = slot_line[1]
          reindented = content.lines.map { |l| l.strip.empty? ? l : "#{indent}#{l}" }.join
          outer_text = outer_text.sub(slot_line[0]) { reindented } # block form — see render's own note on gsub/sub backslash interpretation
        end

        outer_subs.keys.sort_by { |k| -k.length }.each do |marker|
          raise DriftError, "Exemplar.assemble(#{outer_id.inspect}): marker #{marker.inspect} not found in outer shape text" unless outer_text.include?(marker)

          value = outer_subs[marker]
          outer_text = outer_text.gsub(marker) { value }
        end

        if (leftover = outer_text.scan(LEFTOVER_PLACEHOLDER)).any?
          raise DriftError, "Exemplar.assemble(#{outer_id.inspect}): unrendered placeholder(s) #{leftover.uniq.inspect}"
        end

        outer_text
      end

      # Two-level composition for the common single-slot case: a skeleton
      # shape (`outer_id`) that embeds ONE repeatable inner shape
      # (`outer_id:<sub>`, addressed here as `field_id`) — struct field
      # lists, Fielded match arms, JSON object entries, registry router
      # arms. Renders the inner leaf once per entry in `field_subs_list`
      # and hands the joined result to `assemble` as that one slot's
      # content.
      def compose(outer_id, outer_subs, field_id:, field_subs_list:, join_with: "\n")
        assemble(outer_id, outer_subs, slots: { field_id => render_each(field_id, field_subs_list, join_with: join_with) })
      end

      def raw(shape_id)
        shapes.fetch(shape_id) do
          raise DriftError, "Exemplar: no shape #{shape_id.inspect} — " \
                             "checked rust/src/exemplar/*.rs for `// TMPL:#{shape_id} BEGIN`"
        end
      end

      # Test-only: repoints `dir` (default: back to the real exemplar tree)
      # and forces a re-parse, so a spec can swap in a scratch fixture
      # directory without stale memoized state leaking between examples.
      def reset!(dir: DEFAULT_DIR)
        @dir = dir
        @shapes = nil
      end

      private

      def parse_all
        result = {}
        Dir.glob(File.join(dir, "*.rs")).sort.each { |path| parse_file(path, result) }
        result
      end

      def parse_file(path, result)
        stack = [] # each frame: [id, lines, begin_indent]
        File.readlines(path).each do |line|
          if (id = begin_marker(line))
            stack.push([id, [], line[/^[ \t]*/]])
          elsif (id = end_marker(line))
            raise "#{path}: TMPL:#{id} END with no matching BEGIN (stack: #{stack.map(&:first).inspect})" if stack.empty? || stack.last[0] != id

            _, lines, begin_indent = stack.pop
            result[id] = dedent(lines)
            # A sentinel keeps the NESTED region's own indentation — where
            # a marker sat inside its parent (a struct body, a match arm)
            # is what says how deep a real field/arm line belongs, not
            # anything a `compose` caller passes in.
            stack.last[1] << "#{begin_indent}<<TMPL_SLOT:#{id}>>\n" if stack.any?
          elsif stack.any?
            stack.last[1] << line
          end
        end
        raise "#{path}: unclosed TMPL region(s): #{stack.map(&:first).inspect}" if stack.any?
      end

      def begin_marker(line)
        line[%r{//\s*TMPL:(\S+)\s+BEGIN\s*$}, 1]
      end

      def end_marker(line)
        line[%r{//\s*TMPL:(\S+)\s+END\s*$}, 1]
      end

      # Same idea as Ruby's own `<<~` squiggly heredoc: drop whatever
      # leading whitespace every non-blank line shares, so a shape nested
      # three levels deep inside the exemplar's own file indentation comes
      # out reading like top-level Rust, not indented Rust.
      def dedent(lines)
        indents = lines.reject { |l| l.strip.empty? }.map { |l| l[/^[ \t]*/].length }
        margin = indents.min || 0
        lines.map { |l| l.empty? ? l : l[margin..] }.join.rstrip
      end
    end
  end
end

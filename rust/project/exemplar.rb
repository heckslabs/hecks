module RustProjection
  # Loads the `// TMPL:<id> BEGIN/END` shapes in rust/src/exemplar/*.rs and renders them
  # by substituting the fixed `Tmpl`/`tmpl_`/`TMPL_` placeholders with real domain names.
  module Exemplar
    # Matches any placeholder token. After substitution nothing may match, so an
    # unfilled placeholder raises instead of leaking `TmplType` into generated output.
    LEFTOVER_PLACEHOLDER = /\b(?:Tmpl\w*|tmpl_\w*|TMPL_\w*)\b/

    DEFAULT_DIR = File.expand_path("../src/exemplar", __dir__)

    class DriftError < StandardError; end

    class << self
      # Overridable so specs can point at a scratch fixture tree.
      def dir
        @dir ||= DEFAULT_DIR
      end

      # `id` -> raw shape text (dedented, marker lines excluded).
      # A nested region leaves a `<<TMPL_SLOT:<id>:<sub>>>` sentinel; see `compose`.
      def shapes
        @shapes ||= parse_all
      end

      # Renders `shape_id`, replacing each `subs` key (a literal substring) with its value.
      # Raises DriftError on a key absent from the shape or a placeholder left over.
      #
      # Uses the block form of gsub: the two-arg form interprets backslash sequences in
      # the replacement, which corrupts escaped regex sources.
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

      # Renders `shape_id` once per entry in `subs_list`, joined by `join_with`.
      def render_each(shape_id, subs_list, join_with: "\n")
        subs_list.map { |subs| render(shape_id, subs) }.join(join_with)
      end

      # Fills every nested slot of `outer_id` (`slots` maps field_id => rendered content),
      # reindenting each to its marker's depth, then applies `outer_subs` last so a marker
      # cannot match text that came from a slot.
      def assemble(outer_id, outer_subs, slots:)
        outer_text = raw(outer_id)

        slots.each do |field_id, content|
          slot = "<<TMPL_SLOT:#{field_id}>>"
          slot_line = outer_text.match(/^([ \t]*)#{Regexp.escape(slot)}$/)
          raise DriftError, "Exemplar.assemble(#{outer_id.inspect}): no nested slot for #{field_id.inspect} — " \
                             "expected a `// TMPL:#{field_id} BEGIN/END` region nested inside `// TMPL:#{outer_id} BEGIN/END`" unless slot_line

          # The nested marker's indentation in the exemplar sets the depth, not the caller.
          indent = slot_line[1]
          reindented = content.lines.map { |l| l.strip.empty? ? l : "#{indent}#{l}" }.join
          outer_text = outer_text.sub(slot_line[0]) { reindented } # block form: see render
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

      # `assemble` for the single-slot case: renders the inner shape `field_id` once per
      # entry in `field_subs_list` and splices the joined result into `outer_id`.
      def compose(outer_id, outer_subs, field_id:, field_subs_list:, join_with: "\n")
        assemble(outer_id, outer_subs, slots: { field_id => render_each(field_id, field_subs_list, join_with: join_with) })
      end

      def raw(shape_id)
        shapes.fetch(shape_id) do
          raise DriftError, "Exemplar: no shape #{shape_id.inspect} — " \
                             "checked rust/src/exemplar/*.rs for `// TMPL:#{shape_id} BEGIN`"
        end
      end

      # Test-only: repoints `dir` and clears the memoized shapes.
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
            # Keep the nested marker's indentation; it sets the depth of the spliced lines.
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

      # Drops the leading whitespace shared by all non-blank lines, like `<<~`.
      def dedent(lines)
        indents = lines.reject { |l| l.strip.empty? }.map { |l| l[/^[ \t]*/].length }
        margin = indents.min || 0
        lines.map { |l| l.empty? ? l : l[margin..] }.join.rstrip
      end
    end
  end
end

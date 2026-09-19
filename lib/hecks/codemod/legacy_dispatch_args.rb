require "json"
require "prism"

module Hecks
  module Codemod
    # THE REWRITING HALF OF `bin/codemod_legacy_dispatch_args` — reads what
    # `LegacyDispatchRecorder` observed and rewrites each agreed call site
    # from loose keyword facts to `to:` / `with:`:
    #
    #   runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "a" })
    #   # becomes
    #   runtime.dispatch("Banking::Account.FreezeAccount", to: "a")
    #
    # A key that carried receiver identity AND is a declared fact of the
    # command appears in both `to:` and `with:`, and only when its expression
    # is safe to evaluate twice.
    #
    # A site is rewritten only when every recorded dispatch through it split
    # the same way, strict `with:` accepted it (or refused it with the same
    # class the loose call was refused with), no key it would move into `to:`
    # also rode the event payload (`to:` would empty that field for whatever
    # reacts downstream), and the call's own text still
    # carries exactly the recorded keys, identity keys as literal pairs.
    # Anything else is reported with its reason and left alone. Ruby files
    # and the runnable blocks of Markdown guides (the ones `spec/support/
    # doctest.rb` executes) are both rewritten.
    module LegacyDispatchArgs
      ROUTING = %i[to with saga_correlation].freeze
      RUNNABLE_OPENERS = ["```ruby bluebook", "```ruby boot", "```ruby", "<!-- doctest:boot"].freeze

      Plan = Struct.new(:to_keys, :with_keys, :slots, keyword_init: true)
      Outcome = Struct.new(:path, :line, :status, :reason, keyword_init: true)
      Skip = Struct.new(:reason)

      module_function

      # { [path, line] => Plan or Skip }
      def plans(recording)
        File.foreach(recording).map { |line| JSON.parse(line) }
            .select { |entry| entry["site"] }
            .group_by { |entry| entry["site"].rpartition(":").then { |path, _, line| [path, line.to_i] } }
            .transform_values { |entries| plan_for(entries) }
      end

      def plan_for(entries)
        refused = entries.find { |entry| entry["unrewritable"] }
        return Skip.new(refused["unrewritable"]) if refused

        mismatch = entries.find { |entry| entry["strict"] && entry["strict"] != entry["outcome"] }
        if mismatch
          return Skip.new("with: would refuse (#{mismatch['strict']}) where the loose call ended #{mismatch['outcome']}")
        end

        leaked = entries.flat_map { |entry| (entry["to_keys"].to_a - entry["with_keys"].to_a) & entry["payload_keys"].to_a }.uniq
        unless leaked.empty?
          return Skip.new("#{leaked.join(', ')} carries receiver identity AND rides the event payload, " \
                          "which `to:` would empty")
        end

        shapes = entries.map { |entry| [entry["keys"].sort, entry["to_keys"], entry["with_keys"].sort, entry["slots"]] }.uniq
        return Skip.new("the site dispatched #{shapes.size} differently-shaped fact sets") unless shapes.one?

        first = entries.first
        Plan.new(to_keys: first["to_keys"], with_keys: first["with_keys"], slots: first["slots"])
      end

      # [new_text, outcomes] for one file; `site_plans` is { line => Plan or Skip }.
      def rewrite(path, site_plans)
        text = File.binread(path).force_encoding(Encoding::UTF_8)
        outcomes = []
        edits = []

        site_plans.sort.each do |line, plan|
          result = plan.is_a?(Skip) ? plan : edit_for(text, path, line, plan)
          if result.is_a?(Skip)
            outcomes << Outcome.new(path: path, line: line, status: :skipped, reason: result.reason)
          else
            edits << result
            outcomes << Outcome.new(path: path, line: line, status: :rewritten)
          end
        end

        edits.uniq.sort_by { |start, _, _| -start }.each do |start, finish, replacement|
          text = text.byteslice(0, start) + replacement + text.byteslice(finish..)
        end
        [text, outcomes]
      end

      # [start byte, end byte, replacement] in file coordinates, or a Skip.
      def edit_for(text, path, line, plan)
        offset, code, first_line = region(text, path, line)
        return Skip.new("line #{line} is not inside a runnable Ruby block") unless code

        tree = Prism.parse(code, line: first_line)
        return Skip.new("the enclosing Ruby does not parse") unless tree.errors.empty?

        calls = []
        collect_calls(tree.value, line, calls)
        skips = []
        calls.sort_by { |call| call.location.length }.each do |call|
          keywords = call.arguments.arguments.last
          result = replacement_for(keywords, plan)
          if result.is_a?(Skip)
            skips << result
            next
          end

          return [offset + keywords.location.start_offset, offset + keywords.location.end_offset, result]
        end
        skips.first || Skip.new("no call with keyword arguments at line #{line}")
      end

      # The whole file for Ruby; for Markdown, the runnable block containing
      # `line`. [byte offset of the block, its code, its first line number].
      def region(text, path, line)
        return [0, text, 1] unless path.end_with?(".md")

        offset = 0
        open = nil
        text.each_line.with_index(1) do |source_line, number|
          if open
            if source_line.strip == open[:closer]
              if open[:runnable] && (open[:line]...number).cover?(line)
                return [open[:offset], text.byteslice(open[:offset], offset - open[:offset]),
                        open[:line]]
              end

              open = nil
            end
          elsif source_line.start_with?("```", "<!-- doctest:boot")
            opener = source_line.rstrip
            open = { closer: opener.start_with?("<!--") ? "-->" : "```", runnable: RUNNABLE_OPENERS.include?(opener),
                     offset: offset + source_line.bytesize, line: number + 1 }
          end
          offset += source_line.bytesize
        end
        nil
      end

      def collect_calls(node, line, found)
        return unless node

        if node.is_a?(Prism::CallNode) && node.arguments&.arguments&.last.is_a?(Prism::KeywordHashNode) &&
           node.location.start_line <= line && line <= node.location.end_line
          found << node
        end
        node.compact_child_nodes.each { |child| collect_calls(child, line, found) }
      end

      def key_of(element)
        element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) ? element.key.unescaped : nil
      end

      # The rewritten keyword arguments, or why this call does not match the plan.
      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def replacement_for(keywords, plan)
        elements = keywords.elements
        return Skip.new("a keyword with a non-literal key") if elements.any? { |e| e.is_a?(Prism::AssocNode) && key_of(e).nil? }

        routing = elements.select { |element| ROUTING.map(&:to_s).include?(key_of(element)) }
        loose = elements - routing
        return Skip.new("no loose keywords in this call") if loose.empty?
        return Skip.new("to: is spelled in the call but the recording routed by identity") if routing.any? do |e|
          key_of(e) == "to"
        end && !plan.slots.empty?

        literal = loose.filter_map { |element| key_of(element) }
        splats = loose.reject { |element| key_of(element) }
        recorded = (plan.to_keys + plan.with_keys).uniq
        if splats.empty? && literal.sort != recorded.sort
          return Skip.new("the call's keys (#{literal.sort.join(', ')}) are not the recorded keys (#{recorded.sort.join(', ')})")
        end
        if splats.any? && !((literal - recorded).empty? && (plan.to_keys - literal).empty?)
          return Skip.new("a splat carries keys this call does not spell out")
        end

        route = route_text(loose, plan)
        return route if route.is_a?(Skip)

        to_only = loose.select { |element| (plan.to_keys - plan.with_keys).include?(key_of(element)) }
        kept = elements - to_only
        facts = loose - to_only
        positions = facts.map { |element| kept.index(element) }
        return Skip.new("routing keywords sit between the facts") unless positions.each_cons(2).all? { |a, b| b == a + 1 }

        assemble(keywords, kept, facts, route)
      end

      def route_text(loose, plan)
        parts = []
        plan.slots.each do |slot|
          element = loose.find { |candidate| key_of(candidate) == slot["key"] }
          expression = element && identity_expression(element.value, slot)
          return Skip.new("#{slot['key']}: its identity is not spelled the recorded way") unless expression
          if plan.with_keys.include?(slot["key"]) && !pure?(expression)
            return Skip.new("#{slot['key']}: carries identity and a fact, and its expression is not safe to evaluate twice")
          end

          parts[slot["part"]] = expression.slice
        end

        case parts.size
        when 0 then nil
        when 1 then "to: #{parts.first}"
        when 2 then "to: { aggregate: #{parts[0]}, entity: #{parts[1]} }"
        else "to: { aggregate: #{parts[0]}, entities: [#{parts[1..].join(', ')}] }"
        end
      end

      # EVERY FACT KEEPS ITS OWN LINE, RE-ALIGNED. A fact that used to
      # start a line was aligned under whatever the call opened with; once
      # the facts sit inside `with: { `, that column means nothing, so each
      # following fact is re-indented under the FIRST fact's new column
      # (ordinary Ruby hash alignment) and any line inside a single fact's
      # own value is shifted by the same amount, keeping its shape.
      def assemble(keywords, kept, facts, route)
        elements = keywords.elements
        source = keywords.location.slice
        base = keywords.location.start_offset
        gap_after = lambda do |element|
          following = elements[elements.index(element) + 1]
          start = element.location.end_offset - base
          following ? source.byteslice(start, following.location.start_offset - element.location.end_offset) : ", "
        end

        pieces = route ? [route] : []
        column = advance(keywords.location.start_column, pieces.empty? ? "" : "#{route}, ")
        index = 0
        while index < kept.size
          element = kept[index]
          if facts.first.equal?(element)
            pieces << with_clause(facts, column, gap_after)
            index += facts.size
          else
            pieces << element.slice
            index += 1
          end
          column = advance(column, "#{pieces.last}, ")
        end
        pieces.join(", ")
      end

      def with_clause(facts, column, gap_after)
        opener = "with: { "
        fact_column = column + opener.length
        delta = fact_column - facts.first.location.start_column
        body = facts.each_with_index.map do |fact, position|
          gap = position < facts.size - 1 ? gap_after.call(fact).sub(/\n[^\S\n]*\z/, "\n#{' ' * fact_column}") : ""
          reindent(fact.slice, delta) + gap
        end.join
        "#{opener}#{body} }"
      end

      # The column `text` ends at, having started at `column`.
      def advance(column, text)
        before, newline, after = text.rpartition("\n")
        newline.empty? ? column + before.length + after.length : after.length
      end

      # Every line but the first moved right (or left) by `delta`.
      def reindent(text, delta)
        return text if delta.zero? || !text.include?("\n")

        first, _, rest = text.partition("\n")
        "#{first}\n" + rest.gsub(/^[^\S\n]*/) do |indent|
          delta.positive? ? indent + (" " * delta) : indent[0, [indent.length + delta, 0].max]
        end
      end

      def identity_expression(value, slot)
        return value if slot["form"] == "scalar"
        return nil unless value.is_a?(Prism::HashNode) && value.elements.one?

        pair = value.elements.first
        pair.value if key_of(pair) == slot["inner"]
      end

      # Safe to evaluate twice: literals, variable/constant reads, and
      # argument-free method chains over them (`order.id`, `created.instance.id`).
      def pure?(node)
        case node
        when Prism::StringNode, Prism::SymbolNode, Prism::IntegerNode, Prism::FloatNode, Prism::NilNode,
             Prism::TrueNode, Prism::FalseNode, Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode,
             Prism::ConstantReadNode, Prism::ConstantPathNode
          true
        when Prism::InterpolatedStringNode
          node.parts.all? do |part|
            part.is_a?(Prism::StringNode) ||
              (part.is_a?(Prism::EmbeddedStatementsNode) && Array(part.statements&.body).all? { |inner| pure?(inner) })
          end
        when Prism::CallNode
          node.arguments.nil? && node.block.nil? && (node.receiver.nil? || pure?(node.receiver))
        else
          false
        end
      end
    end
  end
end

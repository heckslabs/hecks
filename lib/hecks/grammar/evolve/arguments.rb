module Hecks
  module Grammar
    module Evolve
      # The edits to ArgumentSeed rows: declare an argument, move it through its stations, and
      # follow a keyword's respelling. Extended onto `Hecks::Grammar::Evolve`.
      module Arguments
        # What `propose_argument` fills in for the cells a caller leaves out.
        ARGUMENT_DEFAULTS = { required: "false", at: "", named: "", fills: "", pairs_shape: nil }.freeze

        # Declares a new, proposed argument row; pairs_shape marks a `pairs`
        # argument that fills a whole key/value list, not a single field.
        #
        # @param keyword [String] the keyword the argument belongs to
        # @param context [String] the context the keyword is written in
        # @param kind [String] the argument's kind
        # @param fields [Hash] optionally `required:`, `at:`, `named:`, `fills:` and `pairs_shape:`
        #   cells, and `path:` naming the file(s) to edit
        # @raise [Refusal] when the row is already declared, or no table owns the context
        # @raise [ArgumentError] for any other keyword
        def propose_argument(keyword:, context:, kind:, **fields)
          check_fields!(fields, ARGUMENT_DEFAULTS.keys + [:path])
          cells = ARGUMENT_DEFAULTS.merge(fields.except(:path))
          refuse_declared_argument!(keyword, context, cells, fields[:path])
          path = owner_path(context: context, word: keyword, paths: paths_for(fields[:path]))
          append_member(path, context, "ArgumentSeed") { |indent| argument_member(indent, keyword, context, kind, cells) }
        end

        # @raise [Refusal] when a row with this identity already exists
        def refuse_declared_argument!(keyword, context, cells, path)
          identity = [keyword, context, cells[:at], cells[:named]]
          return unless argument_rows(path).any? { |r| argument_identity(r) == identity }

          raise Refusal, "#{describe_argument(keyword, context, cells[:at], cells[:named])} is " \
                         "already declared — one row per (keyword, context, at, named)"
        end

        # @return [String] the new member row, spelled with `indent`
        def argument_member(indent, keyword, context, kind, cells)
          shape = cells[:pairs_shape].to_s.empty? ? "" : %(pairs_shape: "#{cells[:pairs_shape]}", )
          [%(#{indent}member keyword: "#{keyword}", context: "#{context}", at: "#{cells[:at]}", ),
           %(named: "#{cells[:named]}", kind: "#{kind}", required: "#{cells[:required]}", ),
           %(fills: "#{cells[:fills]}", #{shape}status: "proposed"\n)].join
        end

        # @return [String] how a refusal names the argument row
        def describe_argument(keyword, context, at, named)
          "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect}"
        end

        # Rewrites a declared argument row's status: cell in place.
        #
        # @param where [Hash] optionally `at:` and `named:` (default `""`), and `path:`
        def set_argument_status(keyword:, context:, to:, **where)
          raise Refusal, "#{to.inspect} is not a station an argument's life admits" unless STATIONS.include?(to)

          at = where.fetch(:at, "")
          named = where.fetch(:named, "")
          path = path_holding_argument(keyword, context, at, named, paths_for(where[:path]))
          rewrite_member_rows(path, "ArgumentSeed", ->(line) { argument_row?(line, keyword, context, at, named) },
                              "#{describe_argument(keyword, context, at, named)} is not declared") do |line|
            restatus(line, to)
          end
        end

        # Row-aware rename cascade — updates only the argument rows that belong
        # to the renamed keyword, not a blind gsub across the file.
        def cascade_argument_rename(keyword:, context:, to:, path: nil)
          paths_for(path).each do |candidate|
            original = read_source(candidate)
            source = argument_blocks(original).reduce(original) do |text, block|
              respell_argument_keyword(text, block, keyword, context, to)
            end
            write_source(candidate, source) if source != original
          end
        end

        # @return [String] `text`, with the rows of `block` that belong to `keyword` respelled
        def respell_argument_keyword(text, block, keyword, context, to)
          updated = block.lines.map do |line|
            next line unless line =~ /^\s*member / &&
                             line.include?(%(keyword: "#{keyword}")) && line.include?(%(context: "#{context}"))

            line.sub(%(keyword: "#{keyword}"), %(keyword: "#{to}"))
          end.join
          updated == block ? text : text.sub(block, updated)
        end
      end
    end
  end
end

require_relative "model/deviations"
require_relative "../projector"

module Hecks
  module Projections
    # The model classes' holding half (readers, emission, constructor), projected from the
    # language. `Behaviour::X` stays hand-written behind `settle`, so regenerating is never lossy.
    module Model
      extend Projector::Target

      projects_as :model, declares: "Bluebook", emits: :files

      # Per-construct Ruby facts the grammar does not state (defaults, coercion, class shape).
      HOST = {
        "Policy" => {
          construct: "Policy",
          file:      "policy.rb",
          behaviour: "Behaviour::Policy",
          readers:   %i[name on_event trigger_command target_domain expect_undelivered where for_each with_spec],
          accessors: %i[aggregate],
          defaults:  { name: nil, on_event: "nil", trigger_command: "nil",
                       target_domain: "nil", expect_undelivered: "false", where: "nil", for_each: "nil",
                       with_spec: "[]", aggregate: "nil" },
          # The language holds a flag as "true" and the builder as `true`; both become a boolean.
          coerce:    { name: ".to_s", aggregate: "&.to_s", expect_undelivered: ".to_s == \"true\"" },
          # Bindings render like `DispatchSpec#with_spec`; `render_value` keeps a Symbol's colon
          # so an event-field read and a literal string stay distinguishable.
          renders:   { with_spec: "-> { with_spec.map { |key, value| [key.to_s, Bluebook.render_value(value)] } }",
                       # Computed (Deviations::COMPUTED["Policy"]): derived from `where`.
                       where_ast: "-> { where_ast }" },
          settles:   false
        }
      }.freeze

      module_function

      # Renders every `HOST`-listed construct's holding half.
      #
      # @param bluebook [Bluebook::Chapter] the "Bluebook" chapter itself (the language
      #   describing its own constructs), not a domain being projected
      # @param options [Hash{Symbol => Object}] ignored; present to satisfy the
      #   `Projector::Target` calling convention
      # @return [Hash{String => String}] each construct's output filename mapped to its
      #   rendered Ruby source
      def call(bluebook:, options: {})
        HOST.to_h { |name, host| [host.fetch(:file), render(bluebook, name, host)] }
      end

      # Renders one construct's class: emission, readers and constructor, wrapped in
      # the generated-file header and namespace.
      #
      # @param bluebook [Bluebook::Chapter] the "Bluebook" chapter the construct's own
      #   attributes are read from
      # @param name [String] the construct's name, a key into `HOST` (`"Policy"`, ...)
      # @param host [Hash{Symbol => Object}] `name`'s `HOST` entry
      # @return [String] the rendered class source, ready to write to `host[:file]`
      def render(bluebook, name, host)
        <<~RUBY
          # Generated — projected from the language's own #{name} aggregate.
          # Do not edit: the holding half is rendered, and #{host.fetch(:behaviour)}
          # is where anything hand-written belongs.
          require_relative "behaviour/#{File.basename(host.fetch(:file), '.rb')}"

          module Hecks
            module Bluebook
              class #{name}
                include Hecks::IR
                include #{host.fetch(:behaviour)}

          #{indent(emits(bluebook, name), 6)}

          #{indent(readers(host), 6)}

          #{indent(constructor(host), 6)}
              end
            end
          end
        RUBY
      end

      # Renders the `emits_ir` call. A computed field (Deviations::COMPUTED) rides after the
      # declared ones and needs a `renders` entry, since there is nothing to `send`.
      #
      # @param bluebook [Bluebook::Chapter] the "Bluebook" chapter the construct's own
      #   attributes are read from
      # @param name [String] the construct's name, a key into `HOST`
      # @return [String] the rendered `emits_ir(...)` call, one field per line
      def emits(bluebook, name)
        fields  = emitted_fields(bluebook, name) + Deviations.computed(name)
        renders = HOST.fetch(name).fetch(:renders, {})
        width   = fields.map { |f| f.to_s.length }.max.to_i

        "emits_ir(\n#{fields.map { |f| "  #{"#{f}:".ljust(width + 1)} #{renders.fetch(f, ":#{f}")}" }.join(",\n")}\n)"
      end

      # What the construct emits: the declared attributes less every `Deviations` entry.
      # spec/model_shape_conformance_spec computes it from the same tables.
      #
      # @param bluebook [Bluebook::Chapter] the "Bluebook" chapter the construct's own
      #   attributes are read from
      # @param name [String] the construct's name, an aggregate on `bluebook`
      # @return [Array<Symbol>] the declared attribute names, minus every field
      #   `Deviations` marks as parent-ref, judge-only, off-the-wire, dynamic-tail,
      #   folded, or unpacked
      def emitted_fields(bluebook, name)
        bluebook.aggregate(name).attributes.map(&:name)
                .reject { |f| Deviations.parent_ref?(f) } -
          Deviations.judge_only(name) -
          Deviations.off_the_wire(name) -
          Deviations.dynamic_tail(name) -
          Deviations.folded(name).values.flatten -
          Deviations.unpacked(name).keys
      end

      # Renders the `attr_reader` line for every emitted field, plus an `attr_accessor`
      # for each field the model deliberately keeps off the wire.
      #
      # @param host [Hash{Symbol => Object}] the construct's `HOST` entry
      # @return [String] the rendered reader/accessor lines, one construct's worth
      def readers(host)
        lines = ["attr_reader #{host.fetch(:readers).map { |r| ":#{r}" }.join(', ')}"]
        accessors = host.fetch(:accessors, [])
        return lines.join("\n") if accessors.empty?

        # The off-the-wire reason is emitted so the comment survives regeneration.
        reasons = Deviations::OFF_THE_WIRE.fetch(host.fetch(:construct, ""), {})
        (lines + accessors.map do |a|
          why = reasons[a]
          (why ? "\n# #{a.to_s.capitalize}, declared and deliberately off the wire\n# #{wrap(why)}\n" : "") +
            "attr_accessor :#{a}"
        end).join("\n")
      end

      # Renders the `initialize` that assigns every declared field, coerced as `HOST`
      # states, and calls `settle` unless the construct opts out.
      #
      # @param host [Hash{Symbol => Object}] the construct's `HOST` entry
      # @return [String] the rendered `def initialize ... end` block
      def constructor(host)
        args = host.fetch(:defaults).map { |f, d| d ? "#{f}: #{d}" : "#{f}:" }.join(", ")
        body = host.fetch(:defaults).keys.map do |f|
          "  @#{f} = #{f}#{host.fetch(:coerce, {})[f]}"
        end
        body << "\n  settle" if host.fetch(:settles, true)

        "def initialize(#{args})\n#{body.join("\n")}\nend"
      end

      # Indents every non-blank line of a rendered block, for nesting it inside the
      # class body.
      #
      # @param text [String] the block to indent
      # @param by [Integer] how many spaces to prefix each non-blank line with
      # @return [String] the indented text
      def indent(text, by) = text.lines.map { |l| l.strip.empty? ? l : (" " * by) + l }.join

      # Wraps prose into `# `-prefixed comment lines, for a reader-declared reason
      # rendered back into the generated file.
      #
      # @param text [String] the prose to wrap
      # @return [String] the wrapped text, its lines joined by `"\n# "`
      def wrap(text) = text.scan(/.{1,62}(?:\s|$)/).map(&:strip).join("\n# ")
    end
  end
end

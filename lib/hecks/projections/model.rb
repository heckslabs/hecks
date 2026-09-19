require_relative "model/deviations"
require_relative "../projector"

module Hecks
  module Projections
    # The model classes, projected from the language that declares them.
    #
    # A construct's holding half — its readers, its emission, a
    # constructor that assigns declared fields and hands off — restates
    # what `bluebook.bluebook` already says, three times over in Ruby.
    # This renders it instead.
    #
    # **Only the holding half**. `Behaviour::X` is hand-written and permanent,
    # and `settle` is the seam: everything a declaration cannot state
    # lives behind it, so regenerating can never be lossy. That property
    # was established construct by construct before any of this was
    # written — the chapter looked generatable and was not, until its
    # `@hecks_root`, ports table and child stamping moved behind `settle`.
    #
    # The `HOST` manifest is the honest part. The grammar states the fields;
    # it does not state which constructs are Ruby classes rather than
    # instances, what a constructor's defaults are, or how a value is
    # coerced on the way in. Those are facts about Ruby, not about
    # bluebooks, so they are declared here rather than pretended into the
    # language — and keeping them in one table is what would let a second
    # host swap this file rather than edit thirteen.
    module Model
      extend Projector::Target

      projects_as :model, declares: "Bluebook", emits: :files

      # **Per-construct Ruby facts**. `coerce` is the only fiddly column: a
      # declared field arrives as whatever the builder handed over, and
      # each construct has always normalised its own on the way in.
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
          # A flag on the wire is a boolean — the language holds it as
          # text ("true"), the builder hands over `true`, and a
          # reconstruction hands back whichever it read; all three land
          # as the same `true`/`false`.
          coerce:    { name: ".to_s", aggregate: "&.to_s", expect_undelivered: ".to_s == \"true\"" },
          # A list of bindings is not a scalar on the wire. Every other
          # field emits as itself; this one has to render the way
          # `DispatchSpec`'s own `with_spec` does — keys to strings, and
          # `render_value` keeping the leading colon on a Symbol, because
          # a binding that reads an event field and one that supplies a
          # literal string are otherwise indistinguishable once written
          # down (see `MetaValidator::Readings`' own note on exactly that).
          renders:   { with_spec: "-> { with_spec.map { |key, value| [key.to_s, Bluebook.render_value(value)] } }",
                       # Computed (Deviations::COMPUTED["Policy"]): the structured
                       # form of `where`, a pure function of that text, the same
                       # `ast` every rule row carries beside its `canonical`.
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

      # The emission, keyed as the model spells it and sourced as the
      # language declares it.
      # A computed field (Deviations::COMPUTED) is emitted too — it is
      # model-only by definition, so it rides after the declared fields
      # and must have a `renders` entry, there being nothing to `send`.
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

      # What the construct emits: what the language declares, less every
      # deviation the tables account for. The generator and
      # spec/model_shape_conformance_spec compute this the same way, from
      # the same tables, which is the point of the tables being in lib.
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

        # A declared field the model deliberately does not emit still
        # needs a reader, and the reason it is off the wire is carried
        # here rather than typed in — a comment that survives
        # regeneration is one the generator writes.
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

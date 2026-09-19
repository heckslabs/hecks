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

      # Projects every `HOST`-listed construct as its own generated model
      # file.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   constructs to render
      # @param options [Hash] unused; accepted to satisfy the registry's call shape
      # @return [Hash{String => String}] each construct's `HOST[:file]` filename,
      #   mapped to its rendered Ruby source
      def call(bluebook:, options: {})
        HOST.to_h { |name, host| [host.fetch(:file), render(bluebook, name, host)] }
      end

      # Renders one construct's generated model file: its emission, its
      # readers, and its constructor, wrapped in the class shell `HOST`
      # says it needs.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   aggregate named `name`
      # @param name [String] the construct's name, a `HOST` key (such as `"Policy"`)
      # @param host [Hash] `name`'s `HOST` entry, describing its Ruby shape
      # @return [String] the generated Ruby source for `name`'s model class
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
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   aggregate named `name`
      # @param name [String] the construct's name, a `HOST` key
      # @return [String] the source for an `emits_ir(...)` call listing every
      #   emitted field
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
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   aggregate named `name`
      # @param name [String] the construct's name, a `HOST` key and an aggregate name
      #   `bluebook` declares
      # @return [Array<Symbol>] declared attribute names, less every field a
      #   `Deviations` table accounts for
      def emitted_fields(bluebook, name)
        bluebook.aggregate(name).attributes.map(&:name)
                .reject { |f| Deviations.parent_ref?(f) } -
          Deviations.judge_only(name) -
          Deviations.off_the_wire(name) -
          Deviations.dynamic_tail(name) -
          Deviations.folded(name).values.flatten -
          Deviations.unpacked(name).keys
      end

      # Renders the `attr_reader`/`attr_accessor` block for one construct.
      #
      # @param host [Hash] the construct's `HOST` entry
      # @return [String] the rendered reader and accessor declarations
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

      # Renders the `initialize` method for one construct.
      #
      # @param host [Hash] the construct's `HOST` entry
      # @return [String] the rendered `initialize` method source
      def constructor(host)
        args = host.fetch(:defaults).map { |f, d| d ? "#{f}: #{d}" : "#{f}:" }.join(", ")
        body = host.fetch(:defaults).keys.map do |f|
          "  @#{f} = #{f}#{host.fetch(:coerce, {})[f]}"
        end
        body << "\n  settle" if host.fetch(:settles, true)

        "def initialize(#{args})\n#{body.join("\n")}\nend"
      end

      # Indents every non-blank line of `text` by `by` spaces.
      #
      # @param text [String] the text to indent
      # @param by [Integer] the number of spaces to add to each non-blank line
      # @return [String] `text` with each non-blank line indented
      def indent(text, by) = text.lines.map { |l| l.strip.empty? ? l : (" " * by) + l }.join

      # Wraps `text` at roughly 62 characters, joined as consecutive `#` comment lines.
      #
      # @param text [String] the text to wrap
      # @return [String] `text` re-flowed across lines joined by `"\n# "`
      def wrap(text) = text.scan(/.{1,62}(?:\s|$)/).map(&:strip).join("\n# ")
    end
  end
end

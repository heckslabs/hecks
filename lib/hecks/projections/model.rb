require_relative "model/deviations"
require_relative "../projector"

module Hecks
  module Projections
    # THE MODEL CLASSES, PROJECTED FROM THE LANGUAGE THAT DECLARES THEM.
    #
    # A construct's HOLDING half — its readers, its emission, a
    # constructor that assigns declared fields and hands off — restates
    # what `bluebook.bluebook` already says, three times over in Ruby.
    # This renders it instead.
    #
    # ONLY THE HOLDING HALF. `Behaviour::X` is hand-written and permanent,
    # and `settle` is the seam: everything a declaration cannot state
    # lives behind it, so regenerating can never be lossy. That property
    # was established construct by construct before any of this was
    # written — the chapter looked generatable and was not, until its
    # `@hecks_root`, ports table and child stamping moved behind `settle`.
    #
    # THE HOST MANIFEST IS THE HONEST PART. The grammar states the fields;
    # it does not state which constructs are Ruby CLASSES rather than
    # instances, what a constructor's defaults are, or how a value is
    # coerced on the way in. Those are facts about Ruby, not about
    # bluebooks, so they are declared here rather than pretended into the
    # language — and keeping them in one table is what would let a second
    # host swap this file rather than edit thirteen.
    module Model
      extend Projector::Target

      projects_as :model, declares: "Bluebook", emits: :files

      # PER-CONSTRUCT RUBY FACTS. `coerce` is the only fiddly column: a
      # declared field arrives as whatever the builder handed over, and
      # each construct has always normalised its own on the way in.
      HOST = {
        "Policy" => {
          construct: "Policy",
          file:      "policy.rb",
          behaviour: "Behaviour::Policy",
          readers:   %i[name on_event trigger_command target_domain where for_each with_spec],
          accessors: %i[aggregate],
          defaults:  { name: nil, on_event: "nil", trigger_command: "nil",
                       target_domain: "nil", where: "nil", for_each: "nil",
                       with_spec: "[]", aggregate: "nil" },
          coerce:    { name: ".to_s", aggregate: "&.to_s" },
          # A LIST OF BINDINGS IS NOT A SCALAR ON THE WIRE. Every other
          # field emits as itself; this one has to render the way
          # `DispatchSpec`'s own `with_spec` does — keys to strings, and
          # `render_value` KEEPING the leading colon on a Symbol, because
          # a binding that reads an event field and one that supplies a
          # literal string are otherwise indistinguishable once written
          # down (see `MetaValidator::Readings`' own note on exactly that).
          renders:   { with_spec: "-> { with_spec.map { |key, value| [key.to_s, Bluebook.render_value(value)] } }" },
          settles:   false
        }
      }.freeze

      module_function

      def call(bluebook:, options: {})
        HOST.to_h { |name, host| [host.fetch(:file), render(bluebook, name, host)] }
      end

      def render(bluebook, name, host)
        <<~RUBY
          # GENERATED — projected from the language's own #{name} aggregate.
          # DO NOT EDIT: the holding half is rendered, and #{host.fetch(:behaviour)}
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
      def emits(bluebook, name)
        fields  = emitted_fields(bluebook, name)
        renders = HOST.fetch(name).fetch(:renders, {})
        width   = fields.map { |f| f.to_s.length }.max.to_i

        "emits_ir(\n#{fields.map { |f| "  #{"#{f}:".ljust(width + 1)} #{renders.fetch(f, ":#{f}")}" }.join(",\n")}\n)"
      end

      # WHAT THE CONSTRUCT EMITS: what the language declares, less every
      # deviation the tables account for. The generator and
      # spec/model_shape_conformance_spec compute this the same way, from
      # the same tables, which is the point of the tables being in lib.
      def emitted_fields(bluebook, name)
        bluebook.aggregate(name).attributes.map(&:name)
                .reject { |f| Deviations::PARENT_REF.call(f) } -
          Deviations::JUDGE_ONLY -
          Deviations.off_the_wire(name) -
          Deviations.dynamic_tail(name) -
          Deviations.folded(name).values.flatten -
          Deviations.unpacked(name).keys
      end

      def readers(host)
        lines = ["attr_reader #{host.fetch(:readers).map { |r| ":#{r}" }.join(', ')}"]
        accessors = host.fetch(:accessors, [])
        return lines.join("\n") if accessors.empty?

        # A declared field the model deliberately does not emit still
        # needs a reader, and the REASON it is off the wire is carried
        # here rather than typed in — a comment that survives
        # regeneration is one the generator writes.
        reasons = Deviations::OFF_THE_WIRE.fetch(host.fetch(:construct, ""), {})
        (lines + accessors.map do |a|
          why = reasons[a]
          (why ? "\n# #{a.upcase}, DECLARED AND DELIBERATELY OFF THE WIRE\n# #{wrap(why)}\n" : "") +
            "attr_accessor :#{a}"
        end).join("\n")
      end

      def constructor(host)
        args = host.fetch(:defaults).map { |f, d| d ? "#{f}: #{d}" : "#{f}:" }.join(", ")
        body = host.fetch(:defaults).keys.map do |f|
          "  @#{f} = #{f}#{host.fetch(:coerce, {})[f]}"
        end
        body << "\n  settle" if host.fetch(:settles, true)

        "def initialize(#{args})\n#{body.join("\n")}\nend"
      end

      def indent(text, by) = text.lines.map { |l| l.strip.empty? ? l : (" " * by) + l }.join
      def wrap(text) = text.scan(/.{1,62}(?:\s|$)/).map(&:strip).join("\n# ")
    end
  end
end

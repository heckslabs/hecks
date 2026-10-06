require_relative "era_guard/shape_diff"
require_relative "../../../../bluebook/dsl/malformed"
require_relative "../../../../bluebook/meta_validator"
require_relative "../../../../ports/loading"
require_relative "../../../../runtime/registry"

module Hecks
  module Runtime
    # Shape-drift coverage primitives (ADR 0032). Not a driver: callers own
    # walking a registry and reading/writing held snapshots; nothing here does either.
    module EraGuard
      extend ShapeDiff

      module_function

      # Refuses the boot when a held aggregate is gone and no translation says where it went.
      #
      # A held aggregate matching no current name has no counterpart for a
      # plain per-aggregate diff to compare against; only a `was:` or
      # `retired` translation can explain it.
      #
      # @param registry [Runtime::Registry] the registry searched for a `was:`/`retired` entry
      # @param bluebook [Bluebook::Chapter] the bluebook booting now
      # @param held_bluebook [Bluebook::Chapter] the bluebook parsed from the held era's text
      # @return [void]
      # @raise [Runtime::WiringError] if a held aggregate matches no current aggregate, no
      #   `was:` declares it, and no translation retires it
      def check_vanished_aggregates!(registry, bluebook, held_bluebook)
        held_bluebook.aggregates.each do |held_aggregate|
          claimed = bluebook.aggregates.any? do |aggregate|
            aggregate.name == held_aggregate.name ||
              registry.translations.any? do |translation|
                translation.domain == bluebook.name &&
                  translation.for_aggregate(aggregate.name)&.was == held_aggregate.name
              end
          end
          claimed ||= registry.translations.any? do |translation|
            translation.domain == bluebook.name && translation.retired.include?(held_aggregate.name)
          end
          next if claimed

          raise WiringError,
                "cannot boot #{bluebook.name}: #{held_aggregate.name} existed and now doesn't, " \
                "and nothing declares was: #{held_aggregate.name.inspect} to explain where its data went."
        end
      end

      # Raises the refusal naming every changed path no translation rule explains.
      #
      # The Layer-1 coverage refusal — one wording, shared with whoever
      # calls it (today, `PostgresEra::LineageManager::CoverageCheck`'s
      # own mint-time coverage check).
      #
      # @param bluebook [Bluebook::Chapter] the bluebook booting now, named in the message
      # @param aggregate [Bluebook::Aggregate] the aggregate whose shape changed
      # @param uncovered [Array<String>] the unexplained paths, as `uncovered_attributes`
      #   returns them; must not be empty, since the first one seeds the suggested rule
      # @return [void] never returns; always raises
      # @raise [Runtime::WiringError] always, carrying the refusal wording
      def refuse_uncovered!(bluebook, aggregate, uncovered)
        raise WiringError,
              "cannot boot #{bluebook.name}::#{aggregate.name}: its shape changed and " \
              "#{uncovered.map { |path| render_path(path) }.join(", ")} #{uncovered.size == 1 ? "is" : "are"} not " \
              "explained by any rename, move, convert, retype, or drop. Update bluebook/translations/*.bluebook, e.g. " \
              "#{suggestion(uncovered.first)}."
      end

      # Raises the refusal naming every new required attribute an existing record cannot fill.
      #
      # The addition-side sibling of refuse_uncovered! above — same
      # wording shape, different cause: nothing vanished or changed type,
      # something new arrived that an existing record has no way to hold.
      #
      # @param bluebook [Bluebook::Chapter] the bluebook booting now, named in the message
      # @param aggregate [Bluebook::Aggregate] the aggregate that gained the attributes
      # @param unsafe [Array<Symbol>] the attribute names, as `unsafe_additions` returns them;
      #   must not be empty, since the first one seeds the suggested `backfill`
      # @return [void] never returns; always raises
      # @raise [Runtime::WiringError] always, carrying the refusal wording
      def refuse_unsafe_addition!(bluebook, aggregate, unsafe)
        raise WiringError,
              "cannot boot #{bluebook.name}::#{aggregate.name}: #{unsafe.map { |name| ":#{name}" }.join(", ")} " \
              "#{unsafe.size == 1 ? "is new and required" : "are new and required"}, with no default: to fill " \
              "an existing record and no translation explaining what one should read there. Give it a " \
              "default:, make it optional: true or list_of, or declare bluebook/translations/*.bluebook, e.g. " \
              "`backfill :#{unsafe.first}, default: ...`."
      end

      # Renders a path the way a translation file spells it.
      #
      # @param path [String] a bare attribute name or a dotted value-object member path
      # @return [String] the path quoted (`"price.currency"`) when dotted, otherwise as a
      #   Symbol literal (`:cost`)
      def render_path(path) = path.include?(".") ? path.inspect : ":#{path}"

      # Proposes the translation rules that would explain one uncovered path.
      #
      # @param path [String] a bare attribute name or a dotted value-object member path
      # @return [String] backticked example rules: `move`/`drop` for a dotted path,
      #   `rename`/`drop` for a bare name
      def suggestion(path)
        if path.include?(".")
          "`move #{path.inspect}, to: #{path.inspect}` or `drop #{path.inspect}`"
        else
          "`rename :#{path}, to: :new_name` or `drop :#{path}`"
        end
      end

      # Parses held source into its own IR, in a throwaway registry.
      #
      # Tries the live grammar first, falling back to the shadow one only
      # on `Malformed` — the one signal meaning "not in the live grammar"
      # (ADR 0025); any other exception propagates unchanged.
      #
      # @param source [String] the held bluebook text to evaluate
      # @param path [String] the file path reported as the text's origin
      # @return [Bluebook::Chapter, nil] the first bluebook declared; nil when it declares none
      # @raise [Bluebook::DSL::Malformed] if neither grammar accepts the text
      # @raise [SyntaxError] if the text is not valid Ruby
      def shadow_parse(source, path)
        parse_bluebook(source, path, shadow: false)
      rescue Hecks::Bluebook::DSL::Malformed
        parse_bluebook(source, path, shadow: true)
      end

      # Evaluates bluebook text once, in a throwaway registry, under one chosen grammar.
      #
      # @param source [String] the bluebook text to evaluate
      # @param path [String] the file path reported to `Kernel.eval` as the text's origin
      # @param shadow [Boolean] true evaluates inside `MetaValidator.while_shadow_parsing`
      #   (the shadow grammar); false evaluates under the live grammar
      # @return [Bluebook::Chapter, nil] the first bluebook the text registered in the scratch
      #   registry; nil when it declares none
      # @raise [Bluebook::DSL::Malformed] if the chosen grammar refuses the text
      # @raise [SyntaxError] if the text is not valid Ruby
      def parse_bluebook(source, path, shadow:)
        scratch = Registry.new
        loading = Ports::Loading.bootstrap
        run = lambda do
          Hecks.with_registry(scratch) do
            loading.load_library
            # Held text of a chapter spread over files is several blocks in one string, each
            # opening the same chapter: judge once after all of them, as a directory load does.
            Hecks::Bluebook::MetaValidator.defer { Kernel.eval(source, TOPLEVEL_BINDING, path, 1) }
            Hecks::Bluebook::MetaValidator.judge_deferred!(scratch)
          end
        end
        shadow ? Hecks::Bluebook::MetaValidator.while_shadow_parsing(&run) : run.call
        scratch.bluebooks.values.first
      end
    end
  end
end

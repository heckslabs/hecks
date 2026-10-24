require "hecks"
require "hecks/composer/parse"

module Hecks
  module Composer
    # Runs Hecks's own commands and queries in-process for a command palette and an Eras panel.
    # It is on the hecksagon side like the other composer files: it boots the Hecks chapter once,
    # on first use, and sends argv to the CLI runner one call at a time. A command that is not on
    # the safe list is guarded: it runs only when the caller echoes back a confirmation phrase.
    class Toolbox
      SAFE_COMMANDS = %w[
        model_check_run.model_check operation.run operation.run_behaviors operation.smoke_test
        operation.refresh_projections fuzz_run.fuzz fuzz_run.bench build.check_conformance
        build.fuzz_conformance conformance_run.check_engine_agreement
        conformance_run.measure_doc_coverage kernel_run.measure_kernel_coverage
        style_run.check_comments style_run.check_rust_comments style_run.check_comments_unchanged
      ].freeze

      # A carriage return or line feed.
      LINE_BREAK = /[\r\n]/

      ERA_QUERIES = {
        shape: "introspection.shape", scaffold_translation: "era.scaffold_translation",
        audit_translation: "era.audit_translation", compaction: "era.compaction"
      }.freeze

      # @return [Toolbox] a toolbox that boots the Hecks chapter on first use
      def initialize
        @lock = Mutex.new
        @runtime = nil
      end

      # Everything the palette can offer, commands and queries together.
      #
      # @return [Array<Hash>] `{kind:, verb:, goal:, guarded:}` sorted by verb, without the
      #   commands whose role is System
      def catalog
        (rows("command", commands, :goal) + rows("query", queries, :description))
          .sort_by { |row| [row[:verb], row[:kind]] }
      end

      # The runner's own help text for one verb.
      #
      # @param kind [String] "command" or "query"
      # @param verb [String] a qualified verb such as `model_check_run.model_check`
      # @return [String] the help text
      def help(kind:, verb:)
        invoke(argv_for(kind, verb, [], help: true)).first
      end

      # Runs one command or query and says what it printed.
      #
      # @param kind [String] "command" or "query"
      # @param verb [String] a qualified verb
      # @param args [Hash{String => #to_s}] argument names and values, such as `domain.value`
      # @param confirm [String, nil] the phrase `RUN <verb>` that a guarded command requires
      # @return [Hash] `ok`, `status`, `output` and, when nothing ran or the run failed, `error`
      def run(kind:, verb:, args: {}, confirm: nil)
        refusal = refusal_for(kind, verb, args, confirm)
        return refusal if refusal

        output, status = invoke(argv_for(kind, verb, pairs(args)))
        { ok: status.zero?, status: status, output: output }
      end

      # The four era readings of a workspace.
      #
      # @param dir [String] the workspace directory
      # @return [Hash{Symbol => Hash}] `shape`, `scaffold_translation`, `audit_translation` and
      #   `compaction`, each a {#run} result
      def eras(dir)
        ERA_QUERIES.transform_values { |verb| run(kind: "query", verb: verb, args: { "domain.value" => dir }) }
      end

      private

      # @api private
      def rows(kind, items, reader)
        items.map { |verb, item| entry(kind, verb, item.public_send(reader)) }
      end

      # @api private
      def entry(kind, verb, goal)
        guarded = kind == "command" && !SAFE_COMMANDS.include?(verb)
        { kind: kind, verb: verb, goal: goal.to_s, guarded: guarded }
      end

      # @api private
      def refusal_for(kind, verb, args, confirm)
        return failure(2, "unknown kind #{kind.inspect}") unless %w[command query].include?(kind)
        return failure(2, "unknown #{kind} #{verb.inspect}") unless known(kind).key?(verb.to_s)
        return failure(2, "arguments may not contain a newline") if newline?(args)
        return unless kind == "command" && !SAFE_COMMANDS.include?(verb) && confirm != "RUN #{verb}"

        failure(2, "#{verb} is guarded: confirm with \"RUN #{verb}\"")
      end

      # @api private
      def failure(status, message)
        { ok: false, status: status, output: "", error: message }
      end

      # @api private
      def newline?(args)
        args.any? { |name, value| [name, value].any? { |text| text.to_s.match?(LINE_BREAK) } }
      end

      # @api private
      def pairs(args)
        args.map { |name, value| "#{name}=#{value}" }
      end

      # @api private
      def argv_for(kind, verb, pairs, help: false)
        tail = help ? ["--help"] : pairs
        return ["query", verb, *tail] if kind == "query"

        [verb, *tail, *(help ? [] : ["--wait"])]
      end

      # @api private
      def known(kind)
        kind == "query" ? queries : commands
      end

      # @api private
      def commands
        @commands ||= verbs(:commands).reject { |_verb, command| command.role.to_s == "System" }
      end

      # @api private
      def queries
        @queries ||= verbs(:queries)
      end

      # @api private
      def verbs(member)
        chapter.aggregates.flat_map do |aggregate|
          aggregate.public_send(member).map do |item|
            ["#{Naming.snake(aggregate.hecks_name)}.#{Naming.snake(item.hecks_name)}", item]
          end
        end.to_h
      end

      # @api private
      def chapter
        runtime.registry.bluebook("Hecks")
      end

      # @api private
      def runtime
        @lock.synchronize { @runtime ||= boot }
      end

      # @api private
      def boot
        Hecks.boot(File.join(Parse::ROOT, "lib/hecks/hecks"), install_driving: false, environment: "memory")
      end

      # @api private
      def invoke(argv)
        rt = runtime
        @lock.synchronize do
          Hecks::Adapters::Driving::CliRunner.call(runtime: rt, program: "hecks", argv: argv)
        end
      end
    end
  end
end

require "digest"

module Hecks
  class Runtime

    # Hecks::Runtime::PromptScaffolder
    #
    # Builds the SYSTEM/USER prompt sent to an LLM provider from an
    # `adapter :llm` declaration plus the runtime command + attrs.
    # Output is deterministic and hash-stable (SHA256) so the test
    # provider can key fixtures by `prompt_sha256` and replay the
    # call without flakiness.
    #
    # i23 §6 — `scaffold :command_metadata` shape:
    #
    #   SYSTEM:
    #   You are dispatching the {Aggregate.Command} command.
    #   Description: {command.description}
    #   When to fire: {guards joined with "AND"}
    #   On success, you will set: {then_set pairs}
    #   State fields in scope: {reads}
    #
    #   USER:
    #   {runtime attrs as labeled fields}
    #
    # i23 §10 risk 3 (PII discipline) — strips `pii`-tagged attribute
    # values before scaffolding. Tags come from two sources :
    #   1. `Attribute#pii?` on the aggregate's own attributes
    #   2. The hecksagon's `aggregate_capabilities` table
    #      (`{ "Curator" => [{ attribute: "email", tag: :pii }] }`)
    #
    # i23 §10 risk 7 (loop-guard) — strips runtime attrs whose names
    # match `on_response` targets so a prior response can't echo back
    # into the next prompt as state.
    #
    # ## Phase-2 stub note
    #
    # The Phase 1 IR (`Hecksagon::Structure::LlmAdapter`) does NOT
    # carry `scaffold`, `system`, or `persona_file` fields yet —
    # those are §2 plan items. This step accepts them as keyword
    # arguments to `.build` rather than amending the IR. Step 8
    # (boot wiring) and a follow-up IR amendment will plumb them
    # through from the DSL ; this step's contract is fixed and the
    # dispatcher (step 4) is the sole caller, so the stub surface
    # is self-contained.
    #
    #   result = PromptScaffolder.build(
    #     command:                 cmd,
    #     aggregate:               agg,
    #     attrs:                   { idea: "snow falling" },
    #     scaffold:                :command_metadata,
    #     system:                  "You are Miette. Be concise.",
    #     persona:                 "Tone: gentle.",
    #     aggregate_capabilities:  { "Curator" => [{ attribute: "ssn", tag: :pii }] },
    #     on_response_attrs:       [:response],
    #   )
    #   result.system    # => "You are Miette. ...\nTone: gentle.\n\nYou are dispatching..."
    #   result.user      # => "idea: snow falling"
    #   result.text      # => "SYSTEM:\n...\n\nUSER:\n..."
    #   result.sha256    # => "a3f1..."
    #
    module PromptScaffolder
      # Return shape — `:text` is what gets hashed and shipped to
      # the provider ; the SHA is computed once and frozen here so
      # callers don't need to recompute.
      Result = Struct.new(:system, :user, :text, :sha256, keyword_init: true)

      module_function

      # Build the prompt envelope.
      #
      # @param command [Hecks::BluebookModel::Behavior::Command, nil]
      # @param aggregate [Hecks::BluebookModel::Structure::Aggregate, nil]
      # @param attrs [Hash{Symbol,String=>Object}] runtime dispatch attrs
      # @param scaffold [Symbol, nil] :command_metadata or nil
      # @param system [String, nil] adapter-level system text
      # @param persona [String, nil] adapter-level persona text
      # @param aggregate_capabilities [Hash, nil] hecksagon PII table
      # @param on_response_attrs [Array<Symbol>] loop-guard strip list
      # @return [Result]
      def build(command: nil, aggregate: nil, attrs: {}, scaffold: nil,
                system: nil, persona: nil, aggregate_capabilities: nil,
                on_response_attrs: [])
        pii_attrs = collect_pii_attrs(aggregate, aggregate_capabilities)
        loop_guard = (on_response_attrs || []).map(&:to_sym).to_set
        clean_attrs = sanitize_attrs(attrs, pii_attrs, loop_guard)

        system_text = build_system_section(scaffold, command, aggregate,
                                           system: system, persona: persona)
        user_text   = build_user_section(clean_attrs)
        text        = compose(system_text, user_text)

        Result.new(
          system: system_text,
          user:   user_text,
          text:   text,
          sha256: Digest::SHA256.hexdigest(text),
        )
      end

      # ─── PII + loop-guard ─────────────────────────────────────

      # @return [Set<Symbol>] every attribute name that should be
      #   redacted before scaffolding the USER section.
      def collect_pii_attrs(aggregate, aggregate_capabilities)
        result = []
        if aggregate.respond_to?(:attributes)
          result.concat(aggregate.attributes.select(&:pii?).map(&:name))
        end
        if aggregate && aggregate_capabilities.is_a?(Hash)
          tags = aggregate_capabilities[aggregate.name.to_s] || []
          tags.each do |entry|
            result << entry[:attribute].to_sym if entry.is_a?(Hash) && entry[:tag] == :pii
          end
        end
        result.map(&:to_sym).to_set
      end

      # Drop loop-guard + PII attrs ; symbolize keys for stable order.
      def sanitize_attrs(attrs, pii_attrs, loop_guard)
        sym = (attrs || {}).each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
        sym.reject { |k, _| pii_attrs.include?(k) || loop_guard.include?(k) }
      end

      # ─── SYSTEM section ───────────────────────────────────────

      # Compose adapter-level system + persona + scaffold-driven
      # metadata. Empty pieces are skipped so the joined output has
      # no leading/trailing blank lines.
      def build_system_section(scaffold, command, aggregate, system:, persona:)
        pieces = []
        pieces << system.to_s.strip       unless system.to_s.strip.empty?
        pieces << persona.to_s.strip      unless persona.to_s.strip.empty?
        if scaffold == :command_metadata && command
          pieces << command_metadata_block(command, aggregate)
        end
        pieces.join("\n\n")
      end

      # Render the §6 :command_metadata block deterministically.
      def command_metadata_block(command, aggregate)
        target = qualified_target(command, aggregate)
        lines = []
        lines << "You are dispatching the #{target} command."
        lines << "Description: #{command.description}" if command.respond_to?(:description) && command.description
        guards = render_guards(command)
        lines << "When to fire: #{guards}"        unless guards.empty?
        sets = render_then_set(command)
        lines << "On success, you will set: #{sets}" unless sets.empty?
        reads = render_reads(aggregate)
        lines << "State fields in scope: #{reads}" unless reads.empty?
        lines.join("\n")
      end

      # "Aggregate.Command" — falls back to bare command if no aggregate.
      def qualified_target(command, aggregate)
        cmd_name = command.respond_to?(:name) ? command.name.to_s : command.to_s
        return cmd_name unless aggregate && aggregate.respond_to?(:name)
        "#{aggregate.name}.#{cmd_name}"
      end

      # Joined precondition messages with " AND " — sorted for stability.
      def render_guards(command)
        return "" unless command.respond_to?(:preconditions) && command.preconditions
        msgs = command.preconditions.map { |c| c.respond_to?(:message) ? c.message.to_s : c.to_s }
        msgs.reject(&:empty?).sort.join(" AND ")
      end

      # then_set pairs from `sets` hash AND `mutations` array, sorted.
      def render_then_set(command)
        pairs = []
        if command.respond_to?(:sets) && command.sets
          command.sets.each { |k, v| pairs << "#{k}=#{v}" }
        end
        if command.respond_to?(:mutations) && command.mutations
          command.mutations.each do |m|
            field = m.respond_to?(:field) ? m.field : nil
            value = m.respond_to?(:value) ? m.value : nil
            pairs << "#{field}=#{value}" if field
          end
        end
        pairs.sort.join(", ")
      end

      # Aggregate state fields (sorted, names only — values are runtime).
      def render_reads(aggregate)
        return "" unless aggregate.respond_to?(:attributes) && aggregate.attributes
        aggregate.attributes.map(&:name).map(&:to_s).sort.join(", ")
      end

      # ─── USER section ─────────────────────────────────────────

      # Sorted "key: value" lines — sort guarantees hash-stable output
      # regardless of caller insertion order.
      def build_user_section(attrs)
        attrs.keys.sort.map { |k| "#{k}: #{attrs[k]}" }.join("\n")
      end

      # ─── Compose ──────────────────────────────────────────────

      # Final SYSTEM:\n…\n\nUSER:\n… envelope. Trailing newlines are
      # stripped per section so the SHA stays stable across callers.
      def compose(system_text, user_text)
        parts = []
        parts << "SYSTEM:\n#{system_text}" unless system_text.empty?
        parts << "USER:\n#{user_text}"     unless user_text.empty?
        parts.join("\n\n")
      end
    end
  end
end

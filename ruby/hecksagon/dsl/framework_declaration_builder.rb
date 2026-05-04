# [antibody-exempt: ruby/hecksagon/dsl/framework_declaration_builder.rb —
#  kernel-surface Ruby DSL builder. Phase 1 of adapter-family activation :
#  the Ruby half of the parser-level recognition for the new top-level
#  forms (Hecks.adapter_family / Hecks.provider / Hecks.behavior_kind).
#  Tolerant method_missing intentionally accepts any inner DSL so the
#  framework/* hecksagons load without error before Phase 2 wires the
#  runtime registry. Mirrors the Rust hecksagon_parser's recognition of
#  the same top-level forms — both halves emit byte-equal canonical IR.]
module Hecksagon
  module DSL

    # Hecksagon::DSL::FrameworkDeclarationBuilder
    #
    # DSL builder for the Phase 1 surface of the adapter-family meta-layer
    # (`Hecks.adapter_family`, `Hecks.provider`, `Hecks.behavior_kind`).
    #
    #   builder = FrameworkDeclarationBuilder.new("tts", framework_kind: "adapter_family")
    #   builder.instance_eval(&block)
    #   hex = builder.build  # => Hecksagon::Structure::Hecksagon
    #
    # Phase 1 (parser activation) only captures the file's top-level
    # identity — the family / provider / behavior_kind name plus the
    # `framework_kind` discriminator. Every inner declaration
    # (`fields`, `providers`, `request_body`, `endpoint`, `vision`,
    # `family`, `behavior`, `trigger_field`, ...) is intentionally
    # accepted and silently captured ; the Phase 2 runtime registry
    # builder walks those payloads to drive dispatch.
    #
    # The tolerant `method_missing` keeps the parser stable against
    # future inner-DSL extensions — when Phase 2 adds richer field
    # capture, the same files will continue to parse.
    #
    class FrameworkDeclarationBuilder
      def initialize(name, framework_kind:)
        @name = name
        @framework_kind = framework_kind
      end

      # Phase 1 — accept any inner declaration silently. The IR carries
      # only `name` and `framework_kind`. Phase 2 will replace this with
      # explicit setters that build a richer payload.
      def method_missing(_name, *_args, &block)
        # Block-form sub-DSLs (request_body, voice_settings, endpoint
        # block form) — recurse with the same tolerant builder so nested
        # method calls also no-op rather than raise.
        block&.call if block
        nil
      end

      def respond_to_missing?(_name, _ = false)
        true
      end

      def build
        Hecksagon::Structure::Hecksagon.new(
          name: @name,
          framework_kind: @framework_kind,
        )
      end
    end
  end
end

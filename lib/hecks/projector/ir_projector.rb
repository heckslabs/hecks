module Hecks
  module Projector
    # The trivial case, on purpose: canonical IR projected as canonical
    # IR. `Bluebook#to_h` already satisfies every §30 acceptance
    # criterion on its own — no live runtime needed to call it, output is
    # deterministic (the same golden fixtures `spec/ir_golden_spec.rb`
    # pins), and target-version metadata rides along for free (`§7`'s
    # `ir_version:` is the first key `to_h` emits). Registering it proves
    # the framework's call shape against a real, already-load-bearing
    # target before any genuinely new projector (`:rust`, `:ul`,
    # `:openid`) has to.
    module IRProjector
      module_function

      # Projects `bluebook` as its own canonical IR.
      #
      # @param bluebook [Hecks::IR] the IR-emitting construct to project
      # @param options [Hash] unused; accepted to satisfy the registry's call shape
      # @return [Hash] `bluebook`'s canonical IR, as built by `Hecks::IR::Emits#to_h`
      # @raise [Hecks::IR::Undeclared] if `bluebook` never declared its shape with `emits_ir`
      def call(bluebook:, options: {}) = bluebook.to_h
    end
  end
end

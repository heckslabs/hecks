module Hecksagain
  module Projector
    # The trivial case, on purpose: canonical IR projected AS canonical
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

      def call(bluebook:, options: {}) = bluebook.to_h
    end
  end
end

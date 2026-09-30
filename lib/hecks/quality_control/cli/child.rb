# frozen_string_literal: true

module Hecks
  module QualityControlCli
    # How one QA command starts another as its own OS process, from `lib/` rather than through a
    # `bin/` script: a sweep spawns racers and generated-domain checks, and a launcher query runs
    # any of them. A fresh process is the point: its own boot, its own Postgres connections, and a
    # crash that ends only itself.
    module Child
      # Each command's class, and how it is called: `:argv_root` is `call(ARGV, root:)`, `:argv` is
      # `call(ARGV)` and `:root` is `call(root:)`. A command lives in
      # `hecks/quality_control/cli/<command>`.
      COMMANDS = {
        "qa_tick" => ["QaTick", :argv_root],
        "qa_sweep" => ["QaSweep", :argv_root],
        "qa_pr_check" => ["QaPrCheck", :argv_root],
        "qa_generated_domains" => ["QaGeneratedDomains", :argv_root],
        "qa_mine_combinations" => ["QaMineCombinations", :argv_root],
        "qa_domain_novelty" => ["QaDomainNovelty", :argv_root],
        "qa_discover_external_domains" => ["QaDiscoverExternalDomains", :argv_root],
        "qa_concurrency_racer" => ["QaConcurrencyRacer", :argv_root],
        "qa_postgres_migrate" => ["QaPostgresMigrate", :argv],
        "qa_postgres_role" => ["QaPostgresRole", :argv],
        "qa_seed_angles" => ["QaSeedAngles", :root],
        "qa_seed_targets" => ["QaSeedTargets", :root]
      }.freeze

      module_function

      # @param root [String] the checkout whose `lib/` holds the command and where it runs
      # @param command [String] a key of `COMMANDS`
      # @param args [Array<String>] the command's own arguments
      # @return [Array<String>] the argv that runs it under Bundler, ready for `Process.spawn`
      #   or `Open3` with `chdir: root`
      # @raise [KeyError] when the command is not one of `COMMANDS`
      def argv(root, command, *args)
        klass, style = COMMANDS.fetch(command)
        call = { argv_root: "ARGV, root: #{root.inspect}", argv: "ARGV", root: "root: #{root.inspect}" }.fetch(style)
        code = "require #{"hecks/quality_control/cli/#{command}".inspect}; " \
               "exit(Hecks::QualityControlCli::#{klass}.call(#{call}))"
        ["bundle", "exec", "ruby", "-I", File.join(root, "lib"), "-e", code, "--", *args]
      end
    end
  end
end

require_relative "../../hecks"
require "irb"
# The era/lineage subsystem is a persistence plugin core does not require by default (ADR 0033);
# a domain passed to the console may bind it.
require_relative "../ports/persistence/plugins/era"

module Hecks
  module CLI
    # The command behind `hecks console` and Custodian's `Operation.OpenConsole`: boots a domain
    # (pizzas on Memory by default) and drops into IRB with its door installed, for dispatching a
    # real command by hand. No argument needs no database (ADR 0073); a domain directory boots as
    # it is wired, which may bind PostgresEra (examples/directory does).
    module Console
      PIZZAS = File.expand_path("../../../examples/pizzas", __dir__)

      DEFAULT_FILES = [
        File.join(PIZZAS, "bluebook/pizzas.bluebook"),
        File.join(PIZZAS, "pizzas_behaviors.hecksagon")
      ].freeze

      module_function

      # Boots the domain, prints what it declares, and starts IRB; returns when the session ends.
      #
      # @param domain [String, nil] a domain directory; the bundled pizzas domain when nil
      # @param launcher [#call] starts the interactive session; IRB unless a caller stands in
      # @return [Runtime] the runtime the session ran against
      def call(domain = nil, launcher: -> { irb_session })
        runtime = domain ? Hecks.boot(domain) : Hecks.boot_files(DEFAULT_FILES)
        puts overview(runtime)
        puts banner(domain)
        launcher.call
        runtime
      end

      # Starts IRB with an empty command line. IRB reads `ARGV` for a script to run, and a
      # launcher's `ARGV` holds its own words (`console`, `subject=<domain>`), which IRB would
      # open as a file and then exit without a prompt.
      #
      # @return [void] when the session ends; `ARGV` is restored
      def irb_session
        words = ARGV.dup
        ARGV.clear
        IRB.start(__FILE__)
      ensure
        ARGV.replace(words)
      end

      # @param runtime [Runtime] a booted domain
      # @return [String] each chapter's vision, and its aggregates' descriptions and commands
      def overview(runtime)
        runtime.registry.bluebooks.each_value.map do |bluebook|
          aggregates = bluebook.aggregates.map { |aggregate| aggregate_overview(aggregate) }

          "\n    #{bluebook.name} — #{bluebook.vision}\n#{aggregates.join("\n")}\n"
        end.join
      end

      # @api private
      def aggregate_overview(aggregate)
        commands = aggregate.commands.map { |command| "#{Naming.snake(command.hecks_name)}!" }.sort.join(", ")
        description = aggregate.description.to_s.strip
        lines = ["    #{aggregate.name}: #{commands}"]
        lines << "      #{description}" unless description.empty?
        lines.join("\n")
      end

      # @param domain [String, nil] a domain directory, or nil for the bundled pizzas domain
      # @return [String] the version, and for the pizzas domain a first session to try
      def banner(domain = nil)
        return "\nhecks #{Hecks::VERSION}\n\n" if domain

        <<~BANNER

          hecks #{Hecks::VERSION}

          try:
            order = Order.create_pizza!(name: "Margherita", pizza: { price_cents: { cents: 1200 }, size: "large" })
            order.add_topping!(topping: "Basil", amount: 3)
            order.purchase!(customer_name: "Chris", amount: { cents: 1200 })
            order.status
            order.events.last

        BANNER
      end
    end
  end
end

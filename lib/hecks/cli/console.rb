require_relative "../../hecks"
require "irb"
# The era/lineage subsystem is a persistence plugin core does not require by default (ADR 0033);
# a domain passed to the console may bind it.
require_relative "../ports/persistence/plugins/era"

module Hecks
  module CLI
    # The command behind `bin/console` and Custodian's `Operation.OpenConsole`: boots a domain
    # (pizzas on Memory by default) and drops into IRB with its door installed, for dispatching a
    # real command by hand. No argument needs no database (ADR 0073); a domain directory boots as
    # it is wired, which may bind PostgresEra.
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
      def call(domain = nil, launcher: -> { IRB.start(__FILE__) })
        runtime = domain ? Hecks.boot(domain) : Hecks.boot_files(DEFAULT_FILES)
        puts overview(runtime)
        puts banner
        launcher.call
        runtime
      end

      # @param runtime [Runtime] a booted domain
      # @return [String] each chapter's vision and its aggregates' commands
      def overview(runtime)
        runtime.registry.bluebooks.each_value.map do |bluebook|
          aggregates = bluebook.aggregates.map do |aggregate|
            commands = aggregate.commands.map { |command| "#{Naming.snake(command.hecks_name)}!" }.sort.join(", ")
            "    #{aggregate.name}: #{commands}"
          end

          "\n    #{bluebook.name} — #{bluebook.vision}\n#{aggregates.join("\n")}\n"
        end.join
      end

      # @return [String] the version and a first session to try against the pizzas domain
      def banner
        <<~BANNER

          hecks #{Hecks::VERSION}

          try:
            order = Order.create_pizza!(name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
            order.add_topping!(topping: { value: "Basil" }, amount: { value: 3 })
            order.purchase!(customer_name: { value: "Chris" }, amount: { cents: 1200 })
            order.status
            order.events.last

        BANNER
      end
    end
  end
end

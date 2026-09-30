# frozen_string_literal: true

require_relative "../forms"
require_relative "../forms/banking_presentation"

module Hecks
  module CLI
    # The command behind `bin/present` and `hecks present`: serves the banking example's rendered
    # forms and views, backed by the in-memory adapter
    # (docs/command-form-and-query-form-bluebook.md).
    #
    # Then, for example, `http://localhost:4567/` lists every exposed chapter,
    # `/Banking/Customer.html` every Customer plus Register, `/Banking/Account/Overdrawn.html` a
    # query view, and `/Banking/Account/Debit` answers the command's shape as JSON.
    module Present
      ROOT = File.expand_path("../../..", __dir__)

      module_function

      # Starts a development server and blocks until it stops.
      #
      # @param argv [Array<String>] `[-p port]`
      # @param program [String] the name the refusal calls this command by
      # @param root [String] the checkout whose examples are served
      # @return [void]
      # @raise [SystemExit] when the port argument is refused
      def call(argv, program: "bin/present", root: ROOT)
        require "rackup"
        port, error = Hecks::Forms::PortArgument.parse(argv)
        abort "#{program}: #{error}" if error

        app = Hecks::Forms::BankingPresentation.app(root: root)
        puts "command_form.bluebook/query_form.bluebook — Banking, in memory — http://localhost:#{port}/"
        puts "development server: no authentication, no CSRF protection, no caller identity — do not expose beyond localhost"
        Rackup::Server.start(app: app, Port: port, server: "webrick")
      end
    end
  end
end

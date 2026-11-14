# frozen_string_literal: true

module Hecks
  module Adapters
    # Where the vendored delivery package keeps the Ruby its adapters run, and the one way a file
    # of this repository loads one of them.
    #
    # The package's own `.adapter` files require that Ruby by its place. A file here that needs a
    # class of it (a landing, to tidy after a session) asks through this module, so the place is
    # written once and a moved package breaks one line (ADR 0205).
    module DeliveryLibrary
      # The package's library of adapters, in the vendor slot the Hecks domain attaches it from.
      ROOT = File.expand_path("../../vendor/embryonaut_bluebooks/delivery/lib/adapters", __dir__)

      module_function

      # Loads one file of the package's library.
      #
      # @param name [String] the file, without its extension, as the library names it
      #   (`"git_landing"`, `"git_landing/lineup"`)
      # @return [Boolean] true when this call loaded it, false when it was already loaded
      # @raise [LoadError] when the package holds no such file
      def require(name) = Kernel.require(File.join(ROOT, name))
    end
  end
end

module Hecks

  # Hecks::BootBluebook
  #
  # Opens a BluebookStructure IR — compiles each chapter, wires shared
  # event bus with cross-chapter filtering, and returns runtimes.
  # Delegates to boot_domains for the heavy lifting.
  #
  #   book = Hecks.bluebook("PizzaShop") do
  #     chapter "Pizzas" do ... end
  #     chapter "Billing" do ... end
  #   end
  #   runtimes = Hecks.open(book)
  #
  module BootBluebook
    # Boot a BluebookStructure into running runtimes.
    #
    # @param bluebook [BluebookModel::Structure::BluebookStructure]
    # @return [Array<Runtime>]
    def open(bluebook)
      require_relative "load_extensions"
      LoadExtensions.require_auto

      boot_domains(bluebook.chapters)
    end
  end
end

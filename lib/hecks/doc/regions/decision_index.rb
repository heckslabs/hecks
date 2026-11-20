require "hecks/codemod"
require "hecks/tickets/bluebook/adapters/decision_files"

module Hecks
  module Doc
    module Regions
      # The decision records as `Tickets::Adr` holds them, one table row each: number linked to
      # its file, title, lifecycle status, and the records that supersede or narrow it. Read
      # through the `DecisionFiles` adapter over `docs/decisions`, given the Tickets bluebook's own
      # `Adr` aggregate for its `StatusWord` rows, with no boot: a Memory boot never reads the
      # files. A file the store leaves out is not listed.
      #
      # @example
      #   Hecks::Doc::Regions::DecisionIndex.render(root)
      #   # => "| decision | title | status | superseded by | narrowed by |\n|---|---|..."
      module DecisionIndex
        # The Tickets bluebook, relative to the checkout.
        TICKETS = "lib/hecks/tickets/bluebook/tickets.bluebook".freeze

        # The decision directory, relative to the checkout; the index page sits in it.
        DIRECTORY = "docs/decisions".freeze

        # The table's heading and rule.
        HEAD = "| decision | title | status | superseded by | narrowed by |\n|---|---|---|---|---|".freeze

        module_function

        # @param root [String] the checkout
        # @return [String] every held decision as a Markdown table, by number
        def render(root)
          ([HEAD] + records(root).map { |record| row(record) }).join("\n")
        end

        # @param root [String] the checkout
        # @return [Array<Runtime::Instance>] the records the store holds, by number
        def records(root)
          adr = Codemod.load_bluebook(File.join(root, TICKETS)).bluebook("Tickets").aggregate("Adr")
          store = Adapters::DecisionFiles.new(aggregate: adr, settings: { directory: DIRECTORY }, root: root)
          store.all(order_by: :adr)
        end

        # @param record [Runtime::Instance] one `Adr`
        # @return [String] its table row
        def row(record)
          number = record[:adr][:value]
          link = "[#{number}](#{record[:path][:value].delete_prefix("#{DIRECTORY}/")})"
          cells = [link, record[:title][:value].gsub("|", '\|'), record[:status],
                   numbers(record[:superseded_by]), numbers(record[:narrowed_by])]
          "| #{cells.join(" | ")} |"
        end

        # @param list [Array<Hash>, nil] decision numbers as held
        # @return [String] the numbers, comma separated; empty when none
        def numbers(list) = Array(list).map { |number| number[:value] }.join(", ")
      end
    end
  end
end

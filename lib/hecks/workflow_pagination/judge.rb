module Hecks
  module WorkflowPagination
    # Whether a GitHub API call can take its answer from one page and still be right.
    #
    # A list endpoint answers 30 items a page. A call that counts or waits for items, and reads that
    # one page, is right until the list grows past it and then fails without a word.
    module Judge
      # The last path segment of an endpoint that answers an array, or an object holding one.
      LISTS = %w[artifacts runs jobs issues releases pulls commits comments tags branches labels workflows
                 check-runs check-suites reviews assets].freeze

      # Query terms that narrow a list to the item asked for.
      FILTERS = /(?:\A|&)(?:name|head_sha|sha)=/

      # A call that counts what it reads, or looks one item up by a test.
      COUNTING = /\|\s*length\b|'length'|"length"|wc -l|grep -c|\bcount\b/

      # A call that waits for an item to show among those it reads.
      WAITING = /select\(|grep -q|startswith|contains\(/

      # The words that open a loop which polls.
      LOOP = /\b(?:until|while|seq)\b/

      # A comparison to a fixed number, which bounds how many items the call can need.
      BOUNDED = /(?:=|==|-eq|-ge|-gt|-lt|-le)\s*"?\d+"?/

      module_function

      # @param call [Statement] one API call
      # @return [String, nil] what is wrong with it, or nil when one page is enough
      def fault(call)
        return unless LISTS.include?(call.route.split("/").last) && reads_items?(call)
        return if call.text.include?("--paginate") || call.query.match?(FILTERS)
        return if call.query.include?("per_page=100") && call.after.match?(BOUNDED)

        "counts or waits for the items of #{call.route} from its first page (30 items); " \
          "add --paginate and count the lines it prints, or filter the path with ?name="
      end

      # @return [Boolean] whether the call counts the items or waits for one among them
      def reads_items?(call)
        return true if call.text.match?(COUNTING)

        call.text.match?(WAITING) && call.before.match?(LOOP)
      end
    end
  end
end

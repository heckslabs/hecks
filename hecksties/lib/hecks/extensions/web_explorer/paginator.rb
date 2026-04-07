# Hecks::WebExplorer::Paginator
#
# Simple offset-based paginator for web explorer list views.
# Takes a full array and returns a page slice plus pagination metadata.
#
#   page = Paginator.new(items, page: 2, per_page: 25)
#   page.items       # => [item26, item27, ...]
#   page.total_pages # => 4
#   page.current     # => 2
#
module Hecks
  module WebExplorer
    # Hecks::WebExplorer::Paginator
    #
    # Simple offset-based paginator for web explorer list views.
    #
    class Paginator
      DEFAULT_PER_PAGE = 25

      attr_reader :items, :current, :total_pages, :total_count

      # @param all_items [Array] the full collection to paginate
      # @param page [Integer] 1-based page number
      # @param per_page [Integer] items per page
      def initialize(all_items, page: 1, per_page: DEFAULT_PER_PAGE)
        @total_count = all_items.size
        @current = [page.to_i, 1].max
        @per_page = [per_page.to_i, 1].max
        @total_pages = (@total_count.to_f / @per_page).ceil
        @total_pages = 1 if @total_pages < 1
        offset = (@current - 1) * @per_page
        @items = all_items[offset, @per_page] || []
      end

      def previous_page
        @current > 1 ? @current - 1 : nil
      end

      def next_page
        @current < @total_pages ? @current + 1 : nil
      end
    end
  end
end

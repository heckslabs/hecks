# frozen_string_literal: true

require_relative "glance_facts"

# The facts a `Status` spec hands the adapter, and the row built from them.
module StatusFacts
  include GlanceFacts

  # @return [Hash] a fill report that would start one Work item
  def fill = { would_start: [{ slug: "w", title: "W" }], skipped: [], at: ago(60) }

  # @return [Hash] the `Status` row the facts make, counting also from `since`
  def status(data, since = nil) = described_class.build(data, AT, since)
end

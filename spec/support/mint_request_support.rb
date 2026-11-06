require "pg"

# The mint request the Maintenance mint command hands the era check. A boot never mints, so a spec
# that means to mint names the request itself, at the watermark the database holds when it asks.
module MintRequestSupport
  # @param settings [Hash] the settings a spec would boot the era check with
  # @param domain [String] the domain whose journal's watermark the request reads
  # @return [Hash] the settings, plus a confirmed would_mint request when they allow a mint
  def with_mint_request(settings, domain:)
    return settings unless [true, "true"].include?(settings[:mint_eras])

    request = { confirm: true, verdict: "would_mint", watermark: watermark_of(settings[:database], domain) }
    settings.merge(mint_request: request)
  end

  # @return [Integer] the journal's watermark, or 0 before the domain's journal exists
  def watermark_of(url, domain)
    connection = url.include?("=") || url.start_with?("postgres") ? PG.connect(url) : PG.connect(dbname: url)
    Hecks::Adapters::PostgresRevision::Lineage.new(connection, domain).last_ordinal
  rescue PG::UndefinedTable
    0
  ensure
    connection&.close
  end
end

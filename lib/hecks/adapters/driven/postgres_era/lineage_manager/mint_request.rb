module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # The request a mint carries into the era check: whether the mint was confirmed, the verdict
        # the rehearsal of that same era reached, and the ledger watermark the rehearsal read. Only the
        # Maintenance mint path builds one; a boot has none, so a boot that would mint refuses.
        MintRequest = Data.define(:confirm, :verdict, :watermark) do
          # Reads the request out of a settings hash, spelled with symbol or string keys.
          #
          # @param settings [Hash] the settings the era check was booted with
          # @return [MintRequest, nil] the request, or nil when the settings carry none
          def self.from(settings)
            raw = PostgresEra.setting(settings, :mint_request)
            return nil if raw.nil?

            raw = raw.transform_keys(&:to_sym)
            new(confirm: raw[:confirm] == true, verdict: raw[:verdict].to_s, watermark: raw[:watermark].to_i)
          end
        end
      end
    end
  end
end

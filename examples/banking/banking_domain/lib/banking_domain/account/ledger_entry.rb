require 'hecks/mixins/model'

module BankingDomain
  class Account
    class LedgerEntry
      include Hecks::Model

      attribute :amount
      attribute :description
      attribute :entry_type
      attribute :posted_at
    end
  end
end

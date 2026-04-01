require 'hecks/mixins/model'

module BankingDomain
  class Transfer
    include Hecks::Model

    attribute :from_account_id
    attribute :to_account_id
    attribute :amount
    attribute :status, default: "pending"
    attribute :memo

    private

    def validate!
      raise ValidationError, "amount can't be blank" if amount.nil? || (amount.respond_to?(:empty?) && amount.empty?)
    end
  end
end

require 'hecks/mixins/model'

module BankingDomain
  class Loan
    include Hecks::Model

    attribute :customer_id
    attribute :account_id
    attribute :principal
    attribute :rate
    attribute :term_months
    attribute :remaining_balance
    attribute :status, default: "active"

    private

    def validate!
      raise ValidationError, "principal can't be blank" if principal.nil? || (principal.respond_to?(:empty?) && principal.empty?)
      raise ValidationError, "rate can't be blank" if rate.nil? || (rate.respond_to?(:empty?) && rate.empty?)
    end
  end
end

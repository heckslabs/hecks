require 'hecks/mixins/model'

module BankingDomain
  class Customer
    include Hecks::Model

    attribute :name
    attribute :email
    attribute :status, default: "active"

    private

    def validate!
      raise ValidationError, "name can't be blank" if name.nil? || (name.respond_to?(:empty?) && name.empty?)
      raise ValidationError, "email can't be blank" if email.nil? || (email.respond_to?(:empty?) && email.empty?)
    end
  end
end

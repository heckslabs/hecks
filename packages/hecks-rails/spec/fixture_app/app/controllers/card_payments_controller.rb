# One named action per verb of CardPayment; override one by name and call `super`.
class CardPaymentsController < ApplicationController
  include Hecks::Rails::Controller

  drives CardPayment
end

# One named action per verb of ScheduledPayment; override one by name and call `super`.
class ScheduledPaymentsController < ApplicationController
  include Hecks::Rails::Controller

  drives ScheduledPayment
end

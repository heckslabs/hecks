# One named action per verb of Customer; override one by name and call `super`.
class CustomersController < ApplicationController
  include Hecks::Rails::Controller

  drives Customer
end

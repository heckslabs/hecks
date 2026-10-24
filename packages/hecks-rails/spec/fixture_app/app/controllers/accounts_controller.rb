# One named action per verb of Account; override one by name and call `super`.
class AccountsController < ApplicationController
  include Hecks::Rails::Controller

  drives Account
end

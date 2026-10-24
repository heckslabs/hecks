# One named action per verb of Account; override one by name and call `super`.
class AccountsController < ApplicationController
  include Hecks::Rails::Controller

  drives Account

  # The app's own touch on one generated action: the notice names the account it froze.
  def freeze_account
    super
    flash[:notice] = "Account #{@account.id} is frozen"
  end
end

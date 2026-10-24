# One named action per verb of SafeDepositBox; override one by name and call `super`.
class SafeDepositBoxesController < ApplicationController
  include Hecks::Rails::Controller

  drives SafeDepositBox
end

# One named action per verb of ExternalTransfer; override one by name and call `super`.
class ExternalTransfersController < ApplicationController
  include Hecks::Rails::Controller

  drives ExternalTransfer
end

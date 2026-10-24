# One named action per verb of Transfer; override one by name and call `super`.
class TransfersController < ApplicationController
  include Hecks::Rails::Controller

  drives Transfer
end

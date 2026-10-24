# One named action per verb of ATMCard; override one by name and call `super`.
class AtmCardsController < ApplicationController
  include Hecks::Rails::Controller

  drives AtmCard
end

# One named action per verb of Statement; override one by name and call `super`.
class StatementsController < ApplicationController
  include Hecks::Rails::Controller

  drives Statement
end

# One named action per verb of OnboardingCase; override one by name and call `super`.
class OnboardingCasesController < ApplicationController
  include Hecks::Rails::Controller

  drives OnboardingCase
end

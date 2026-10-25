# Joins the domain by its name. The app's only code is who is signed in, here read from a header.
class AccountsController < ActionController::Base
  Person = Struct.new(:id)

  def current_user
    id = request.headers["X-Actor"]
    id && Person.new(id)
  end
end

# A model the app wrote because it has a presentation method; the railtie generates the rest.
class Note < ApplicationRecord
  def headline = text.value.upcase
end

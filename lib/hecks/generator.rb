# Hecks::Generator
#
# Base class for all Hecks code generators. Provides NamingHelpers
# and the generate contract. Subclasses implement #generate to return
# generated source (String) or structured data (Hash).
#
#   class MyGenerator < Hecks::Generator
#     def generate
#       "class #{domain_constant_name(@model.name)}; end"
#     end
#   end
#

module Hecks
  class Generator
    include Hecks::Conventions::NamingHelpers

    def generate
      raise NotImplementedError, "#{self.class}#generate not implemented"
    end
  end
end

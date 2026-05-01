# = HecksMongodb
#
# MongoDB persistence adapter for Hecks domains. Provides document-based
# repository adapters using the mongo Ruby driver. Each aggregate maps
# to a MongoDB collection.
#
# == Usage
#
#   app = Hecks.boot(__dir__, adapter: :mongodb)
#   app = Hecks.boot(__dir__, adapter: { type: :mongodb, uri: "mongodb://localhost:27017/mydb" })
#
require "hecks_mongodb/mongo_boot"
require "hecks_mongodb/mongo_adapter_generator"

Hecks.register_adapter(:mongodb)

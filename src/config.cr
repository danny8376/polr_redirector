require "yaml"

struct Config
  struct Bind
    include YAML::Serializable
    property host : String
    property port : Int32
    property unix : String
    property perm : Int16
  end
  struct SiteConfig
    include YAML::Serializable
    property db_uri        : String
    property analytics_db_uri : String
    property adv_analytics : Bool
    property fetch_404     : Bool
    property scheme        : String
    property geo_db        : String
  end
  include YAML::Serializable
  property bind   : Bind
  property geo_db : String
  property sites  : Hash(String, SiteConfig)
end

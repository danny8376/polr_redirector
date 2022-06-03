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
    struct Cache
      include YAML::Serializable
      property size       : Int32
      property expire     : Int32
      property neg_expire : Int32
    end
    include YAML::Serializable
    property dot_env   : String
    @[YAML::Field(ignore: true)]
    property db_uri    : String = ""
    property db_conf   : String
    property analytics_db_conf : String
    @[YAML::Field(ignore: true)]
    property adv_analytics : Bool = false
    property cache     : Cache
    property fetch_404 : Bool
    property scheme    : String
    property geo_db    : String
  end
  include YAML::Serializable
  property bind   : Bind
  property geo_db : String
  property sites  : Hash(String, SiteConfig)
end

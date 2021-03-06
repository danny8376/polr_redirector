require "poncho"
require "kemal"
require "uri"
require "db"
require "mysql"
require "lru-cache"
require "geoip2"

require "./config"

class Cache(K, V) < LRUCache(K, V)
  def initialize(*, max_size : Int32? = nil, @expire : Time::Span? = nil, @neg_expire : Time::Span? = nil)
    super(max_size: max_size)
  end

  def set(key : K, value : V, neg : Bool = false)
    expire = neg ? @neg_expire : @expire
    set(key, value, expire.nil? ? nil : Time.utc + expire)
  end
end

alias CacheTuple = Tuple(Int8, String, String, Int32?)
Sites = Hash(String, Tuple(DB::Database, DB::Database, GeoIP2::Database?, Cache(String, CacheTuple)?)).new
E404Cache = Hash(String, String).new

struct Config
  @@conf = Config.from_yaml(File.read("./config.yml.example"))
  private macro geo_db(sc)
    sc.geo_db.empty? ? @@conf.geo_db : sc.geo_db
  end
  private macro use_adb(sc)
    sc.adv_analytics && !sc.analytics_db_conf.empty?
  end
  private macro cache(sc)
    if sc.cache.size > 0
      Cache(String, CacheTuple).new(max_size: sc.cache.size, expire: sc.cache.expire.seconds, neg_expire: sc.cache.neg_expire.seconds)
    else
      nil
    end
  end
  def self.fetch404(site)
    spawn { E404Cache[site] = HTTP::Client.get("#{@@conf.sites[site].scheme}://#{site}/admin/this/page/does/not/exist").body }
  end
  def self.parse_env
    @@conf.sites.transform_values! do |sc|
      e = Poncho::Parser.from_file sc.dot_env
      sc.db_uri = "#{e["DB_CONNECTION"]}://#{e["DB_USERNAME"]}:#{e["DB_PASSWORD"]}@#{e["DB_HOST"]}:#{e["DB_PORT"]}/#{e["DB_DATABASE"]}"
      sc.adv_analytics = e["SETTING_ADV_ANALYTICS"] == "true"
      sc
    end
  end
  def self.load(yaml = File.read("./config.yml"))
    old_conf = @@conf
    @@conf = Config.from_yaml yaml
    parse_env
    old_sites = Sites.keys
    new_sites = @@conf.sites.keys
    (old_sites - new_sites).each do |site|
      Sites.delete(site).try do |db, adb, _, _|
        db.close
        adb.close
      end
      E404Cache.delete(site)
    end
    (new_sites - old_sites).each do |site|
      sc = Config.conf.sites[site]
      geo = GeoIP2.open(geo_db(sc)) rescue nil
      db = DB.open(sc.db_uri + sc.db_conf)
      adb = use_adb(sc) ? DB.open(sc.db_uri + sc.analytics_db_conf) : db
      Sites[site] = {db, adb, geo, cache(sc)}
      fetch404 site if sc.fetch_404
    end
    (new_sites & old_sites).each do |site|
      odb, oadb, _, _ = Sites[site]
      osc, sc = old_conf.sites[site], @@conf.sites[site]
      db = if osc.db_uri == sc.db_uri && osc.db_conf == sc.db_conf
             odb
           else
             odb.close
             DB.open(sc.db_uri + sc.db_conf)
           end
      adb = if use_adb(osc) == use_adb(sc) && osc.db_uri == sc.db_uri && osc.analytics_db_conf == sc.analytics_db_conf
              oadb
            else
              oadb.close if use_adb(osc)
              use_adb(sc) ? DB.open(sc.db_uri + sc.analytics_db_conf) : db
            end
      geo = GeoIP2.open(geo_db(sc)) rescue nil
      Sites[site] = {db, adb, geo, cache(sc)}
      if sc.fetch_404
        fetch404 site
      else
        E404Cache.delete(site)
      end
    end
    @@conf
  end
  def self.conf
    @@conf
  end
end
Config.load

def redirect(env, url)
  env.redirect url, 301, body: "<!DOCTYPE html><html><head><meta charset=\"UTF-8\" /><meta http-equiv=\"refresh\" content=\"0;url=#{url}\" /><title>Redirecting to #{url}</title></head><body>Redirecting to <a href=\"#{url}\">#{url}</a>.</body></html>"
end

def response(env, code, body = "")
  env.response.status_code = code
  env.response.print body
end

def query_link(db, cache, short_url)
  val = cache.try &.get(short_url)
  if val.nil?
    db.query "SELECT is_disabled, secret_key, long_url, id FROM `links` WHERE short_url=?", short_url do |rs|
      if rs.move_next
        val = rs.read Int8, String, String, Int32
        cache.try &.set(short_url, val)
      else
        val = {0_i8, "", "", nil}
        cache.try &.set(short_url, val, neg: true)
      end
    end
  end
  val
end

def do_redirect(env)
  host = env.request.headers["Host"]?
  short_url = env.params.url["short_url"]
  secret_key = env.params.url["secret_key"]?
  site = Sites[host]?
  if site
    site.try do |db, adb, geo, cache|
      link_data = query_link db, cache, short_url
      if link_data.nil?
        response env, 404
      else
        is_disabled, link_secret_key, long_url, id = link_data
        if id.nil?
          response env, 404
        else
          if is_disabled != 0
            response env, 404
            return
          end
          if !link_secret_key.empty? && secret_key != link_secret_key
            response env, 403
            return
          end
          headers = env.request.headers
          now = Time.utc
          spawn do # do analytics in another fiber to reduce the response speed
            adb.exec "UPDATE `links` SET clicks=clicks+1 WHERE short_url=?", short_url
            Config.conf.sites[host].try do |sc|
              if sc.adv_analytics
                ip = headers["X-Real-IP"]
                country = geo.try(&.country?(ip)).try(&.country.iso_code) rescue nil
                referer = headers["Referer"]?
                rhost = URI.parse(referer.not_nil!).host rescue nil
                ua = headers["User-Agent"]?
                adb.exec "INSERT INTO `clicks` (ip, country, referer, referer_host, user_agent, link_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", ip, country, referer, rhost, ua, id, now, now
              end
            end
          end
          redirect env, long_url
        end
      end
    end
  else
    response env, 404, "site not exist"
  end
end

before_all do |env|
  env.response.headers["Cache-Control"] = "no-cache"
end

get "/:short_url" do |env|
  do_redirect env
end

get "/:short_url/:secret_key" do |env|
  do_redirect env
end

error 404 do |env|
  E404Cache[env.request.headers["Host"]?]? || "HTTP 404"
end

Signal::HUP.trap do
  puts "Recived HUP, reloading config (only affect sites part)"
  Config.load
end

Kemal.run do |config|
  bind = Config.conf.bind
  server = config.server.not_nil!

  if bind.unix.empty?
    server.bind_tcp bind.host, bind.port
  else
    server.bind_unix bind.unix
    File.chmod(bind.unix, bind.perm)
  end
end


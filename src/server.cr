require "kemal"
require "uri"
require "db"
require "mysql"
require "geoip2"

require "./config"

Sites = Hash(String, Tuple(DB::Database, DB::Database, GeoIP2::Database?)).new
E404Cache = Hash(String, String).new

struct Config
  @@conf = Config.from_yaml(File.read("./config.yml.example"))
  private macro geo_db(sc)
    sc.geo_db.empty? ? @@conf.geo_db : sc.geo_db
  end
  private macro use_adb(sc)
    sc.adv_analytics && !sc.analytics_db_uri.empty?
  end
  def self.load(yaml = File.read("./config.yml"))
    old_conf = @@conf
    @@conf = Config.from_yaml yaml
    old_sites = Sites.keys
    new_sites = @@conf.sites.keys
    (old_sites - new_sites).each do |site|
      Sites.delete(site).try do |db, adb, _|
        db.close
        adb.close
      end
      E404Cache.delete(site)
    end
    (new_sites - old_sites).each do |site|
      sc = Config.conf.sites[site]
      geo = GeoIP2.open(geo_db(sc)) rescue nil
      db = DB.open(sc.db_uri)
      adb = use_adb(sc) ? DB.open(sc.analytics_db_uri) : db
      Sites[site] = {db, adb, geo}
      spawn { E404Cache[site] = HTTP::Client.get("#{sc.scheme}://#{site}/admin/this/page/does/not/exist").body } if sc.fetch_404
    end
    (new_sites & old_sites).each do |site|
      odb, oadb, _ = Sites[site]
      osc, sc = old_conf.sites[site], @@conf.sites[site]
      db = if osc.db_uri == sc.db_uri
             odb
           else
             odb.close
             odb.close
             odb.close
             DB.open(sc.db_uri)
           end
      adb = if use_adb(osc) == use_adb(sc) && osc.analytics_db_uri == sc.analytics_db_uri
              oadb
            else
              oadb.close if use_adb(osc)
              use_adb(sc) ? DB.open(sc.analytics_db_uri) : db
            end
      geo = GeoIP2.open(geo_db(sc)) rescue nil
      Sites[site] = {db, adb, geo}
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

def do_redirect(env)
  host = env.request.headers["Host"]?
  short_url = env.params.url["short_url"]
  secret_key = env.params.url["secret_key"]?
  site = Sites[host]?
  if site
    site.try do |db, adb, geo|
      db.query "SELECT is_disabled, secret_key, long_url, id FROM `links` WHERE short_url=?", short_url do |rs|
        if rs.move_next
          is_disabled, link_secret_key, long_url, id = rs.read Int8, String, String, Int32
          if is_disabled != 0
            response env, 404
            return
          end
          if !link_secret_key.empty? && secret_key != link_secret_key
            response env, 403
            return
          end
          db.exec "UPDATE `links` SET clicks=clicks+1 WHERE short_url=?", short_url
          Config.conf.sites[host].try do |sc|
            if sc.adv_analytics
              headers = env.request.headers
              spawn do # do this in another fiber to reduce the response speed
                ip = headers["X-Real-IP"]
                country = geo.try(&.country?(ip)).try(&.country.iso_code) rescue nil
                referer = headers["Referer"]?
                rhost = URI.parse(referer.not_nil!).host rescue nil
                ua = headers["User-Agent"]?
                adb.exec "INSERT INTO `clicks` (ip, country, referer, referer_host, user_agent, link_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", ip, country, referer, rhost, ua, id
              end
            end
          end
          redirect env, long_url
        else
          response env, 404
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
  host = env.request.headers["Host"]?
  if Config.conf.sites[host]?.try &.fetch_404
    E404Cache[host]? || "HTTP 404"
  else
    "HTTP 404"
  end
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


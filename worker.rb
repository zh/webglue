require 'rubygems'
require 'sequel'
require 'zlib'
require 'json'
require 'crack'
require 'atom'
require 'eventmachine'
require 'httpclient'

begin
  require 'system_timer'
  MyTimer = SystemTimer
rescue
  require 'timeout'
  MyTimer = Timeout
end

require 'topics'

DB = Sequel.connect(ENV['DATABASE_URL'] || 'sqlite://webglue.db')

module WebGlue

  class Client
    include EM::Deferrable

    def do_verify(url, query, debug = false)
      begin
         MyTimer.timeout(Config::GIVEUP) do
           res = HTTPClient.get_content(url, query)
           raise "do_verify(#{url})" unless res and res == query['hub.challenge']
        end
        sleep(0.05)
        set_deferred_status(:succeeded)
      rescue Exception => e
        puts e.to_s if debug == true
        set_deferred_status(:failed)
      end
    end
  end

  class Worker

    def self.gen_id
      base = rand(100000000).to_s
      salt = Time.now.to_s
      Zlib.crc32(base + salt).to_s(36)
    end

    # spawn a new process for every backend to check
    def self.verify_all(debug = Config.DEBUG)
      subs = DB[:subscriptions].filter(:vmode => 'async', :state => 1)
      subs.each do |sub|
        url = Topic.to_url(sub[:callback])
        topic =  DB[:topics].filter(:id => sub[:topic_id]).first
        topic = Topic.to_url(topic[:url]) if topic
        query = { 'hub.mode' => sub[:vmode],
                  'hub.topic' => topic,
                  'hub.lease_seconds' => 0,  # still no subscription refreshing support
                  'hub.challenge' => self.gen_id,
                  'hub.verify_token' => sub[:vtoken]}
        EM.spawn do
          client = Client.new
          client.callback do
            DB[:subscriptions].filter(:callback => sub[:callback]).update(:state => 0)
            puts "sucess: #{url}" if debug == true
          end
          client.errback { puts "fail: #{url}" if debug == true }
          client.do_verify(url, query, debug)
        end.notify
      end
    end

    # run the check once (for example from a cronjob)
    def self.verify
      EM.epoll   # Only on Linux 2.6.x
      EM.run do
        self.verify_all(true)
        EM.stop
      end
    end

    def self.run
      EM.epoll   # Only on Linux 2.6.x
      EM.run do
        # 5 min checks
        EM::PeriodicTimer.new(Config::CHECK) do
          self.verify_all(false)
        end  
      end
    end

  end
end

if __FILE__ == $0
  trap("INT") { EM.stop }

  # one time check (cronjob)
  WebGlue::Worker.verify
  
  # continious working 
  #WebGlue::Worker.run
end

require 'rubygems'
require 'sinatra'
require 'sequel'
require 'zlib'
require 'json'
require 'crack'
require 'httpclient'
require 'atom'

begin
  require 'system_timer'
  MyTimer = SystemTimer
rescue
  require 'timeout'
  MyTimer = Timeout
end

require 'topics'

module WebGlue

  class Config
    GIVEUP = 10
  end  

  class App < Sinatra::Default
  
    set :sessions, false
    set :run, false
    set :environment, ENV['RACK_ENV']
  
    configure do
      DB = Sequel.connect(ENV['DATABASE_URL'] || 'sqlite://webglue.db')
    
      unless DB.table_exists? "topics"
        DB.create_table :topics do
          primary_key :id
          varchar     :url, :size => 128
          time        :created
          time        :updated
          index       [:updated] 
          index       [:url], :unique => true
        end
      end
    
      unless DB.table_exists? "subscriptions"
        DB.create_table :subscriptions do
          primary_key :id
          foreign_key :topic_id
          varchar     :callback, :size => 128
          varchar     :vtoken, :size => 32
          integer     :state, :default => 0  # 0 - verified, 1 - need verification
          time        :created
          index       [:created] 
          index       [:topic_id, :callback], :unique => true
        end
      end
    end
    
    helpers do
      def gen_id
        base = rand(100000000).to_s
        salt = Time.now.to_s
        Zlib.crc32(base + salt).to_s(36)
      end
    
      def atom_time(date)
        date.getgm.strftime("%Y-%m-%dT%H:%M:%SZ")
      end
    
      def atom_parse(text)
        atom = Crack::XML.parse(text)
        r = []
        if atom["feed"]["entry"].kind_of?(Array)
          atom["feed"]["entry"].each { |e| 
            r << {:id => e["id"], :title => e["title"], :published => e["published"] }
          }
        else
          e = atom["feed"]["entry"]
          r = {:id => e["id"], :title => e["title"], :published => e["published"] }
        end
        r
      end
    
      # post a message to a list of subscribers (urls)
      def postman(subs, msg)
        subs.each do |sub|
          begin
            MyTimer.timeout(Config::GIVEUP) do
              HTTPClient.post(sub, msg)
            end
          rescue Exception => e
            case e
              when Timeout::Error
                puts "Timeout: #{sub}"
              else  
                puts e.to_s
            end  
            next
          end
        end
      end
    
      # Publishers pinging this URL, when there is new content
      def do_publish(params)
        unless params['hub.url'] and not params['hub.url'].empty?
          throw :halt, [400, "Bad request: Empty or missing 'hub.url' parameter"]
        end
        begin 
          hash = WebGlue::Topic.to_hash(params['hub.url'])
          topic = DB[:topics].filter(:url => hash)
          if topic.first # already registered
            # minimum 5 min interval between pings
            time_diff = (Time.now - topic.first[:updated]).to_i
            #throw :halt, [200, "204 Try after #{(300-time_diff)/60 +1} min"] if time_diff < 300
            topic.update(:updated => Time.now)
            subscribers = DB[:subscriptions].filter(:topic_id => topic.first[:id])
            urls = subscribers.collect { |u| WebGlue::Topic.to_url(u[:callback]) }
            atom_diff = WebGlue::Topic.diff(params['hub.url'], true)
            postman(urls, atom_diff) if (urls.length > 0 and atom_diff)
          else  
            DB[:topics] << { :url => hash, :created => Time.now, :updated => Time.now }
          end
          throw :halt, [204, "204 No Content"]
        rescue Exception => e
          throw :halt, [404, e.to_s]
        end
      end
      
      # Subscribe to existing topics
      def do_subscribe(params)
        mode     = params['hub.mode']
        callback = params['hub.callback']
        topic    = params['hub.topic']
        verify   = params['hub.verify']
        vtoken   = params['hub.verify_token']
        unless callback and topic and verify
          throw :halt, [400, "Bad request: Expected 'hub.callback', 'hub.topic', and 'hub.verify'"]
        end
        throw :halt, [400, "Bad request: Empty 'hub.callback' or 'hub.topic'"]  if callback.empty? or topic.empty?
        throw :halt, [400, "Bad request: Unrecognized mode"] unless ['subscribe', 'unsubscribe'].include?(mode)
        
        # For now, only using the first preference of verify mode 
        verify = verify.split(',').first 
        # throw :halt, [400, "Bad request: Unrecognized verification mode"] unless ['sync', 'async'].include?(verify)
        # will support only 'sync' mode for now
        throw :halt, [400, "Bad request: Unrecognized verification mode"] unless verify == 'sync'
        begin
          hash =  WebGlue::Topic.to_hash(topic)
          tp =  DB[:topics].filter(:url => hash).first
          throw :halt, [404, "Not Found"] unless tp[:id]
          
          state = (verify == 'async') ? 1 : 0
          query = { 'hub.mode' => mode,
                    'hub.topic' => topic,
                    'hub.challenge' => gen_id,
                    'hub.verify_token' => vtoken}
          if verify == 'sync'
            MyTimer.timeout(Config::GIVEUP) do
              res = HTTPClient.get_content(callback, query)
              raise "do_verify(#{callback})" unless res and res == query['hub.challenge']
            end
            state = 0
          end
      
          # Add subscription
          # subscribe/unsubscribe to/from ALL channels with that topic
          cb =  WebGlue::Topic.to_hash(callback)
          if mode == 'subscribe'
            unless DB[:subscriptions].filter(:topic_id => tp[:id], :callback => cb).first
              raise "DB insert failed" unless DB[:subscriptions] << {
                :topic_id => tp[:id], :callback => cb, :vtoken => vtoken, :state => state }
            end
            throw :halt, [202, "202 Scheduled for verification"] if verify == 'async'
          else # mode = 'unsubscribe'
            DB[:subscriptions].filter(:topic_id => tp[:id], :callback => cb).delete
          end
          throw :halt, [204, "204 No Content"]
        rescue Exception => e
          throw :halt, [409, "Subscription verification failed: #{e.to_s}"]
        end
      end
    
    end
    
    # Debug registering new topics
    get '/publish' do
      erb :publish
    end
    
    # Debug subscribe to PubSubHubbub
    get '/subscribe' do
      erb :subscribe
    end
    
    # Main hub endpoint for both publisher and subscribers
    post '/' do
      throw :halt, [400, "Bad request, missing 'hub.mode' parameter"] unless params['hub.mode']
      if params['hub.mode'] == 'publish'
        do_publish(params)
      elsif params['hub.mode'] == 'subscribe'
        do_subscribe(params)
      else  
        throw :halt, [400, "Bad request, unknown 'hub.mode' parameter"]
      end
    end
  
  end
end

require 'rubygems'
require 'sinatra'
require 'sequel'
require 'zlib'
require 'json'
require 'crack'
require 'httpclient'
require 'atom'
require 'hmac-sha1'

begin
  require 'system_timer'
  MyTimer = SystemTimer
rescue
  require 'timeout'
  MyTimer = Timeout
end

require 'topics'

module WebGlue

  class App < Sinatra::Default
  
    set :sessions, false
    set :run, false
    set :environment, ENV['RACK_ENV']
  
    configure do
      DB = Sequel.connect(ENV['DATABASE_URL'] || 'sqlite://webglue.db')
    
      unless DB.table_exists? "topics"
        DB.create_table :topics do
          primary_key :id
          varchar     :url, :size => 256
          time        :created
          time        :updated
          integer     :dirty, :default => 1  # 0 - no changes, 1 - need resync
          index       [:updated] 
          index       [:dirty] 
          index       [:url], :unique => true
        end
      end
    
      unless DB.table_exists? "subscriptions"
        DB.create_table :subscriptions do
          primary_key :id
          foreign_key :topic_id
          varchar     :callback, :size => 256
          varchar     :vtoken, :size => 64
          varchar     :secret, :size => 64
          varchar     :vmode, :size => 32    # 'sync' or 'async'
          integer     :state, :default => 0  # 0 - verified, 1 - need verification
          time        :created
          index       [:created] 
          index       [:vmode] 
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
    
      # post a message to a list of subscribers (urls)
      def postman(subs, msg)
        extheaders = { 'Content-Type' => 'application/atom+xml' }
        subs.each do |sub|
          begin
            url = Topic.to_url(sub[:callback])
            unless sub[:secret].empty?
              signature = HMAC::SHA1.hexdigest(sub[:secret], msg)
              extheaders['X-Hub-Signature'] = "sha1=#{signature}"
            end  
            MyTimer.timeout(Config::GIVEUP) do
              HTTPClient.post(url, msg, extheaders)
            end
          rescue Exception => e
            if Config::DEBUG == true
              case e
                when Timeout::Error
                  puts "Timeout: #{sub}"
                else  
                  puts e.to_s 
              end
            end 
            next
          end
        end
      end
    
      # Publishers pinging this URL, when there is new content
      def do_publish(params)
        content_type 'text/plain', :charset => 'utf-8'
        unless params['hub.url'] and not params['hub.url'].empty?
          throw :halt, [400, "Bad request: Empty or missing 'hub.url' parameter"]
        end
        begin
          # TODO: move the subscribers notifications to some background job (worker?)
          hash = Topic.to_hash(params['hub.url'])
          topic = DB[:topics].filter(:url => hash)
          if topic.first # already registered
            # minimum 5 min interval between pings
            time_diff = (Time.now - topic.first[:updated]).to_i
            throw :halt, [204, "204 Try after #{(300-time_diff)/60 +1} min"] if time_diff < 300
            topic.update(:updated => Time.now, :dirty => 1)
            # only verified subscribers, subscribed to that topic
            subscribers = DB[:subscriptions].filter(:topic_id => topic.first[:id], :state => 0)
            atom_diff = Topic.diff(params['hub.url'], true)
            postman(subscribers, atom_diff) if (subscribers.count > 0 and atom_diff)
            topic.update(:dirty => 0)
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
        
        content_type 'text/plain', :charset => 'utf-8'
        unless callback and topic and verify
          throw :halt, [400, "Bad request: Expected 'hub.callback', 'hub.topic', and 'hub.verify'"]
        end
        throw :halt, [400, "Bad request: Empty 'hub.callback' or 'hub.topic'"]  if (callback.empty? or topic.empty?)
        # anchor part in the url not allowed by the spec
        throw :halt, [400, "Bad request: Invalid URL"] if (callback.include?('#') or topic.include?('#'))
        
        throw :halt, [400, "Bad request: Unrecognized mode"] unless ['subscribe', 'unsubscribe'].include?(mode)

        # Processing optional secret
        secret = params['hub.secret'] ? params['hub.secret'] : ''
       
        # remove invalid verify modes 
        verify = Array(verify.split(',')).delete_if { |x| not ['sync','async'].include?(x) }
        throw :halt, [400, "Bad request: Unrecognized verification mode"] if verify.empty?
        # For now, only using the first preference of verify mode
        verify = verify[0]
        #throw :halt, [400, "Bad request: Unrecognized verification mode"] unless ['sync', 'async'].include?(verify)
        begin
          hash =  Topic.to_hash(topic)
          tp =  DB[:topics].filter(:url => hash).first
          throw :halt, [404, "Not Found"] unless tp[:id]
          
          state = (verify == 'async') ? 1 : 0
          query = { 'hub.mode' => mode,
                    'hub.topic' => topic,
                    'hub.lease_seconds' => 0,  # still no subscription refreshing support
                    'hub.challenge' => gen_id}
          query['hub.verify_token'] = vtoken if vtoken
          if verify == 'sync'
            MyTimer.timeout(Config::GIVEUP) do
              res = HTTPClient.get_content(callback, query)
              opts = "m=#{mode} c=#{callback} t=#{topic} v=#{verify} -> res=#{res.inspect}"
              raise "do_verify(#{opts})" unless res and res == query['hub.challenge']
            end
            state = 0
          end
      
          # Add subscription
          # subscribe/unsubscribe to/from ALL channels with that topic
          cb =  DB[:subscriptions].filter(:topic_id => tp[:id], :callback => Topic.to_hash(callback))
          cb.delete if (mode == 'unsubscribe' or cb.first)
          if mode == 'subscribe'
            raise "DB insert failed" unless DB[:subscriptions] << {
              :topic_id => tp[:id], :callback => Topic.to_hash(callback), 
              :vtoken => vtoken, :vmode => verify, :secret => secret, :state => state }
          end
          throw :halt, verify == 'async' ? [202, "202 Scheduled for verification"] : 
                                           [204, "204 No Content"]
        rescue Exception => e
          throw :halt, [409, "Subscription verification failed: #{e.to_s}"]
        end
      end
    
    end
    
    get '/' do
      erb :index
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
      content_type 'text/plain', :charset => 'utf-8'
      throw :halt, [400, "Bad request, missing 'hub.mode' parameter"] unless params['hub.mode']
      case(params['hub.mode'])
        when 'publish' then do_publish(params)
        when 'subscribe', 'unsubscribe' then do_subscribe(params)
        else throw :halt, [400, "Bad request, unknown 'hub.mode' parameter"]
      end  
    end
  
  end
end

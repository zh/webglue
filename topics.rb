# Small fix for feeds with 'xhtml' type content
module Atom
  class Content
    class Xhtml < Base
      def to_xml(nodeonly = true, name = 'content', namespace = nil, namespace_map = Atom::Xml::NamespaceMap.new)
        node = XML::Node.new("#{namespace_map.prefix(Atom::NAMESPACE, name)}")
        node['type'] = 'xhtml'
        # fixed line - FriendFeed send 'xhtml' type content WITHOUT xml_lang :(
        node['xml:lang'] = self.xml_lang ? self.xml_lang : "en"

        div = XML::Node.new('div')
        div['xmlns'] = XHTML

        p = XML::Parser.string(to_s)
        content = p.parse.root.copy(true)
        div << content

        node << div
        node
      end  
    end
  end  
end  

module WebGlue

  FEEDS_DIR=(File.join(File.dirname(__FILE__), 'feeds')).freeze

  class InvalidTopicException < Exception; end

  class Topic

    attr_reader  :entries

    def Topic.feeds_dir()
      return FEEDS_DIR
    end  

    def Topic.to_hash(url)
      [url].pack("m*").strip!
    end

    def Topic.to_url(hash)
      hash.unpack("m")[0]
    end   

    def Topic.sync(url)
      raise InvalidTopicException unless url
      feed = nil
      begin
        MyTimer.timeout(GIVEUP) do
          feed = Atom::Feed.load_feed(URI.parse(url))
        end
      rescue
        raise InvalidTopicException
      end  
      raise InvalidTopicException unless feed
      return feed
    end

    def Topic.load_file(hash)
      path = File.join(FEEDS_DIR,"#{hash}.yml")
      raise InvalidTopicException unless File.exists?(path)
      return YAML::load_file(path)
    end  

    def Topic.load_url(url)
      raise InvalidTopicException unless url
      h = Topic.to_hash(url)
      return Topic.load_file(h)
    end  

    def Topic.save!(url, feed)
      raise InvalidTopicException unless (url and feed)
      h = Topic.to_hash(url)
      File.open(File.join(FEEDS_DIR,"#{h}.yml"), "w") do |out|
        YAML::dump(feed, out)
      end  
    end

    def Topic.diff(url, to_atom = false)
      raise InvalidTopicException unless url
      
      begin
        old_feed = Topic.load_url(url)
        urls = old_feed.entries.collect {|e| e.links.first.href }
      rescue InvalidTopicException
        urls = []
      end  

      new_feed = nil
      begin
        MyTimer.timeout(GIVEUP) do
          new_feed = Atom::Feed.load_feed(URI.parse(url))
        end
      rescue Exception => e
        raise e.to_s
      end  
      raise InvalidTopicException unless new_feed

      Topic.save!(url, new_feed)

      new_feed.entries.delete_if {|e| urls.include?(e.links.first.href) }
      return nil unless urls.length > 0 # do not send everything first time
      return nil unless new_feed.entries.length > 0
      return to_atom ? new_feed.to_xml : new_feed.entries
    end

    def Topic.atom_diff(url)
    end  
  end  
end  

module Faye
  class Channel
    
    include Observable
    attr_reader :name
    
    def initialize(name)
      @name = name
    end
    
    def <<(message)
      changed(true)
      notify_observers(:message, message)
    end
    
    HANDSHAKE   = '/meta/handshake'
    CONNECT     = '/meta/connect'
    SUBSCRIBE   = '/meta/subscribe'
    UNSUBSCRIBE = '/meta/unsubscribe'
    DISCONNECT  = '/meta/disconnect'
    CLIENTS     = '/meta/clients'
    
    META        = :meta
    SERVICE     = :service
    
    class << self
      def valid?(name)
        Grammar::CHANNEL_NAME =~ name or
        Grammar::CHANNEL_PATTERN =~ name
      end
      
      def parse(name)
        return nil unless valid?(name)
        name.split('/')[1..-1].map { |s| s.to_sym }
      end
      
      def meta?(name)
        segments = parse(name)
        segments ? (segments.first == META) : nil
      end
      
      def service?(name)
        segments = parse(name)
        segments ? (segments.first == SERVICE) : nil
      end
      
      def subscribable?(name)
        return nil unless valid?(name)
        not meta?(name) and not service?(name)
      end
    end
    
    class Tree
      include Enumerable
      attr_accessor :value
      
      def initialize(value = nil)
        @value = value
        @children = {}
      end
      
      def each_child
        @children.each { |key, subtree| yield(key, subtree) }
      end
      
      def each(prefix = [], &block)
        each_child { |path, subtree| subtree.each(prefix + [path], &block) }
        yield(prefix, @value) unless @value.nil?
      end
      
      def [](name)
        subtree = traverse(name)
        subtree ? subtree.value : nil
      end
      
      def []=(name, value)
        subtree = traverse(name, true)
        subtree.value = value unless subtree.nil?
      end
      
      def traverse(path, create_if_absent = false)
        path = Channel.parse(path) if String === path
        
        return nil if path.nil?
        return self if path.empty?
        
        subtree = @children[path.first]
        return nil if subtree.nil? and not create_if_absent
        subtree = @children[path.first] = self.class.new if subtree.nil?
        
        subtree.traverse(path[1..-1], create_if_absent)
      end
      
      def glob(path = [])
        path = Channel.parse(path) if String === path
        
        return [] if path.nil?
        return @value.nil? ? [] : [@value] if path.empty?
        
        if path == [:*]
          return @children.inject([]) do |list, (key, subtree)|
            list << subtree.value unless subtree.value.nil?
            list
          end
        end
        
        if path == [:**]
          list = map { |key, value| value }
          list.pop unless @value.nil?
          return list
        end
        
        list = @children.values_at(path.first, :*).
                         compact.
                         map { |t| t.glob(path[1..-1]) }
        
        list << @children[:**].value if @children[:**]
        list.flatten
      end
    end
    
  end
end


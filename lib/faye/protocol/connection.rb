module Faye
  class Connection
    include EventMachine::Deferrable
    include Publisher
    include Timeouts
    
    MAX_DELAY = 0.1
    INTERVAL  = 0.0
    TIMEOUT   = 60.0
    
    attr_reader :id, :interval, :timeout
    attr_accessor :channel_usernames
    
    def initialize(id, options = {})
      @id        = id
      @options   = options
      @interval  = @options[:interval] || INTERVAL
      @timeout   = @options[:timeout] || TIMEOUT
      @channels  = Set.new
      @inbox     = Set.new
      @connected = false
      @channel_usernames = {}
      
      begin_deletion_timeout
    end
    
    def socket=(socket)
      @connected = true
      @socket    = socket
    end
    
    def on_message(event)
      return unless @inbox.add?(event)
      @socket.send(JSON.unparse(event)) if @socket
      begin_delivery_timeout
    end
    
    def subscribe(channel, username = 'anonymous')
      return unless @channels.add?(channel)
      channel.add_subscriber(:message, method(:on_message))
      @channel_usernames[channel.name] = username
    end
    
    def unsubscribe(channel)
      return @channels.each(&method(:unsubscribe)) if channel == :all
      return unless @channels.member?(channel)
      @channels.delete(channel)
      channel.remove_subscriber(:message, method(:on_message))
      @channel_usernames.delete(channel.name)
    end
    
    def connect(options, &block)
      options = options || {}
      timeout = options['timeout'] ? options['timeout'] / 1000.0 : @timeout
      
      set_deferred_status(:deferred)
      
      callback(&block)
      return if @connected
      
      @connected = true
      remove_timeout(:deletion)
      
      begin_delivery_timeout
      begin_connection_timeout(timeout)
    end
    
    def flush!
      return unless @connected
      release_connection!
      
      events = @inbox.entries
      @inbox = Set.new
      
      set_deferred_status(:succeeded, events)
      set_deferred_status(:deferred)
    end
    
    def disconnect!
      unsubscribe(:all)
      flush!
    end
    
  private
    
    def release_connection!
      return if @socket
      
      remove_timeout(:connection)
      remove_timeout(:delivery)
      @connected = false
      
      begin_deletion_timeout
    end
    
    def begin_delivery_timeout
      return unless @connected and not @inbox.empty?
      add_timeout(:delivery, MAX_DELAY) { flush! }
    end
    
    def begin_connection_timeout(timeout)
      return unless @connected
      add_timeout(:connection, timeout) { flush! }
    end
    
    def begin_deletion_timeout
      return if @connected
      add_timeout(:deletion, TIMEOUT + 10 * @timeout) do
        publish_event(:stale_connection, self)
      end
    end
    
  end
end


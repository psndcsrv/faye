module Faye
  class Server
    def initialize(options = {})
      @options   = options
      @channels  = Channel::Tree.new
      @clients   = {}
      @namespace = Namespace.new
    end
    
    # Notifies the server of stale connections that should be deleted
    def update(message, client)
      return unless message == :stale_client
      destroy_client(client)
    end
    
    def client_ids
      @clients.keys
    end
    
    def client_names(channel_name)
      # FIXME We should really be able to get a list of connections for a channel, and then just .collect on that
      @clients.values.collect{|c| c.username(channel_name)}.compact
    end
    
    def process(messages, local = false, &callback)
      messages = [messages].flatten
      processed, responses = 0, []
      
      messages.each do |message|
        handle(message, local) do |reply|
          reply = [reply].flatten
          responses.concat(reply)
          processed += 1
          callback[responses] if processed == messages.size
        end
      end
    end
    
    def flush_connection(messages)
      [messages].flatten.each do |message|
        client = @clients[message['clientId']]
        client.flush! if client
      end
    end
    
  private
    
    def connection(id)
      return @clients[id] if @clients.has_key?(id)
      client = Connection.new(id, @options)
      client.add_observer(self)
      @clients[id] = client
    end
    
    def destroy_client(client)
      client.disconnect!
      client.delete_observer(self)
      @clients.delete(client.id)
    end
    
    def handle(message, local = false, &callback)
      client_id = message['clientId']
      channel   = message['channel']
      
      if Channel.subscribable_meta?(channel)
        message = __send__(Channel.parse(channel)[1], message, local)
        return message unless local
      end
      
      @channels.glob(channel).each { |c| c << message }
      
      if Channel.meta?(channel)
        response = __send__(Channel.parse(channel)[1], message, local)
        
        client_id ||= response['clientId']
        response['advice'] ||= {}
        response['advice']['reconnect'] ||= @clients.has_key?(client_id) ? 'retry' : 'handshake'
        response['advice']['interval']  ||= Connection::INTERVAL * 1000
        
        response['id'] = message['id']
        
        return callback[response] unless response['channel'] == Channel::CONNECT and
                                         response['successful'] == true
        
        return connection(response['clientId']).connect do |events|
          callback[[response] + events]
        end
      end
      
      return callback[[]] if message['clientId'].nil? or Channel.service?(channel)
      
      callback[ { 'channel'     => channel,
                  'successful'  => true,
                  'id'          => message['id']  } ]
    end
    
    # MUST contain  * version
    #               * supportedConnectionTypes
    # MAY contain   * minimumVersion
    #               * ext
    #               * id
    def handshake(message, local = false)
      response =  { 'channel' => Channel::HANDSHAKE,
                    'version' => BAYEUX_VERSION,
                    'id'      => message['id'] }
      
      response['error'] = Error.parameter_missing('version') if message['version'].nil?
      
      unless local
        response['supportedConnectionTypes'] = CONNECTION_TYPES
        
        client_conns = message['supportedConnectionTypes']
        if client_conns
          common_conns = client_conns.select { |c| CONNECTION_TYPES.include?(c) }
          response['error'] = Error.conntype_mismatch(*client_conns) if common_conns.empty?
        else
          response['error'] = Error.parameter_missing('supportedConnectionTypes')
        end
      end
      
      response['successful'] = response['error'].nil?
      return response unless response['successful']
      
      client_id = @namespace.generate
      response['clientId'] = connection(client_id).id
      response
    end
    
    # MUST contain  * clientId
    #               * connectionType
    # MAY contain   * ext
    #               * id
    def connect(message, local = false)
      response  = { 'channel' => Channel::CONNECT,
                    'id'      => message['id'] }
      
      client_id = message['clientId']
      client    = client_id ? @clients[client_id] : nil
      
      response['error'] = Error.client_unknown(client_id) if client.nil?
      response['error'] = Error.parameter_missing('clientId') if client_id.nil?
      response['error'] = Error.parameter_missing('connectionType') if message['connectionType'].nil?
      
      response['successful'] = response['error'].nil?
      return response unless response['successful']
      
      response['clientId'] = client.id
      response
    end
    
    # MUST contain  * clientId
    # MAY contain   * ext
    #               * id
    def disconnect(message, local = false)
      response  = { 'channel' => Channel::DISCONNECT,
                    'id'      => message['id'] }
      
      client_id = message['clientId']
      client    = client_id ? @clients[client_id] : nil
      
      response['error'] = Error.client_unknown(client_id) if client.nil?
      response['error'] = Error.parameter_missing('clientId') if client_id.nil?
      
      response['successful'] = response['error'].nil?
      return response unless response['successful']
      
      destroy_client(client)
      
      response['clientId'] = client_id
      response
    end
    
    # MUST contain  * clientId
    #               * subscription
    #               * username
    # MAY contain   * ext
    #               * id
    def subscribe(message, local = false)
      response      = { 'channel'   => Channel::SUBSCRIBE,
                        'clientId'  => message['clientId'],
                        'id'        => message['id'] }
      
      client_id     = message['clientId']
      client        = client_id ? @clients[client_id] : nil
      
      subscription  = message['subscription']
      subscription  = [subscription].flatten
      
      response['error'] = Error.client_unknown(client_id) if client.nil?
      response['error'] = Error.parameter_missing('clientId') if client_id.nil?
      response['error'] = Error.parameter_missing('subscription') if message['subscription'].nil?     
      response['error'] = Error.parameter_missing('username') if message['username'].nil?
      
      username = message['username'] ? message['username'] : 'anonymous'
      
      response['subscription'] = subscription.compact
      
      subscription.each do |channel|
        next if response['error']
        response['error'] = Error.channel_forbidden(channel) unless local or Channel.subscribable?(channel)
        response['error'] = Error.channel_invalid(channel) unless Channel.valid?(channel)
        
        next if response['error']
        channel = @channels[channel] ||= Channel.new(channel)
        client.subscribe(channel, username)
        
        if (! Channel.subscribable_meta?(channel.name))
          # send notification to the clients subscribable metadata channel
          smeta_message = { "channel" =>"/smeta/clients#{channel.name}",
                            "real_channel" => channel.name,
                            "data" => {"message" => "subscribe"},
                            "clientId" => client_id
                          }
          handle(smeta_message, true) {|r| nil }
        end
      end
      
      response['successful'] = response['error'].nil?
      response
    end
    
    # MUST contain  * clientId
    #               * subscription
    # MAY contain   * ext
    #               * id
    def unsubscribe(message, local = false)
      response      = { 'channel'   => Channel::UNSUBSCRIBE,
                        'clientId'  => message['clientId'],
                        'id'        => message['id'] }
      
      client_id     = message['clientId']
      client        = client_id ? @clients[client_id] : nil
      
      subscription  = message['subscription']
      subscription  = [subscription].flatten
      
      response['error'] = Error.client_unknown(client_id) if client.nil?
      response['error'] = Error.parameter_missing('clientId') if client_id.nil?
      response['error'] = Error.parameter_missing('subscription') if message['subscription'].nil?
      
      response['subscription'] = subscription.compact
      
      subscription.each do |channel|
        next if response['error']
        
        if not Channel.valid?(channel)
          response['error'] = Error.channel_invalid(channel)
          next
        end
        
        channel = @channels[channel]
        if channel
          client.unsubscribe(channel)
          if (! Channel.subscribable_meta?(channel.name))
            # send notification to the clients subscribable metadata channel
            smeta_message = { "channel" =>"/smeta/clients#{channel.name}",
                              "real_channel" => channel.name,
                              "data" => {"message" => "unsubscribe"},
                              "clientId" => client_id
                             }
            handle(smeta_message, true) {|r| nil }
          end
        end
      end
      
      response['successful'] = response['error'].nil?
      response
    end
    
    def clients(message, local = false)
      message['data'] = client_names(message["real_channel"])
      message
    end
    
  end
end


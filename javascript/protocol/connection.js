Faye.Connection = Faye.Class({
  MAX_DELAY:  <%= Faye::Connection::MAX_DELAY %>,
  INTERVAL:   <%= Faye::Connection::INTERVAL %>,
  TIMEOUT:    <%= Faye::Connection::TIMEOUT %>,
  
  initialize: function(id, options) {
    this.id         = id;
    this._options   = options;
    this.interval   = this._options.interval || this.INTERVAL;
    this.timeout    = this._options.timeout || this.TIMEOUT;
    this._channels  = new Faye.Set();
    this._inbox     = new Faye.Set();
    this._connected = false;
    this._channel_usernames  = {};
    
    this._beginDeletionTimeout();
  },
  
  setSocket: function(socket) {
    this._connected = true;
    this._socket    = socket;
  },
  
  _onMessage: function(event) {
    if (!this._inbox.add(event)) return;
    if (this._socket) this._socket.send(Faye.toJSON(event));
    this._beginDeliveryTimeout();
  },
  
  subscribe: function(channel, username) {
    if (!this._channels.add(channel)) return;
    if (username) {
      this._channel_usernames[channel.name] = username;
    } else {
	    this._channel_usernames[channel.name] = 'anonymous';
    }
    channel.addSubscriber('message', this._onMessage, this);
  },
  
  unsubscribe: function(channel) {
    if (channel === 'all') return this._channels.forEach(this.unsubscribe, this);
    if (!this._channels.member(channel)) return;
    this._channels.remove(channel);
    this._channel_usernames[channel.name] = null;
    channel.removeSubscriber('message', this._onMessage, this);
  },
  
  connect: function(options, callback, scope) {
    options = options || {};
    var timeout = (options.timeout !== undefined) ? options.timeout / 1000 : this.timeout;
    
    this.setDeferredStatus('deferred');
    
    this.callback(callback, scope);
    if (this._connected) return;
    
    this._connected = true;
    this.removeTimeout('deletion');
    
    this._beginDeliveryTimeout();
    this._beginConnectionTimeout(timeout);
  },
  
  flush: function() {
    if (!this._connected) return;
    this._releaseConnection();
    
    var events = this._inbox.toArray();
    this._inbox = new Faye.Set();
    
    this.setDeferredStatus('succeeded', events);
    this.setDeferredStatus('deferred');
  },
  
  disconnect: function() {
    this.unsubscribe('all');
    this.flush();
  },
  
  username: function(channel_name) {
	  return this._channel_usernames[channel_name];
  },
  
  _releaseConnection: function() {
    if (this._socket) return;
    
    this.removeTimeout('connection');
    this.removeTimeout('delivery');
    this._connected = false;
    
    this._beginDeletionTimeout();
  },
  
  _beginDeliveryTimeout: function() {
    if (!this._connected || this._inbox.isEmpty()) return;
    this.addTimeout('delivery', this.MAX_DELAY, this.flush, this);
  },
  
  _beginConnectionTimeout: function(timeout) {
    if (!this._connected) return;
    this.addTimeout('connection', timeout, this.flush, this);
  },
  
  _beginDeletionTimeout: function() {
    if (this._connected) return;
    this.addTimeout('deletion', this.TIMEOUT + 10 * this.timeout, function() {
      this.publishEvent('staleConnection', this);
    }, this);
  }
});

Faye.extend(Faye.Connection.prototype, Faye.Deferrable);
Faye.extend(Faye.Connection.prototype, Faye.Publisher);
Faye.extend(Faye.Connection.prototype, Faye.Timeouts);


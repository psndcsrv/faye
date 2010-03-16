Faye.Connection = Faye.Class({
  MAX_DELAY:  <%= Faye::Connection::MAX_DELAY %>,
  INTERVAL:   <%= Faye::Connection::INTERVAL %>,
  TIMEOUT:    <%= Faye::Connection::TIMEOUT %>,
  
  initialize: function(id, options) {
    this.id         = id;
    this._options   = options;
    this._channels  = new Faye.Set();
    this._inbox     = new Faye.Set();
    this._channel_usernames  = {};
  },
  
  getTimeout: function() {
    return this._options.timeout || this.TIMEOUT;
  },
  
  _onMessage: function(event) {
    this._inbox.add(event);
    this._beginDeliveryTimeout();
  },
  
  subscribe: function(channel, username) {
    if (!this._channels.add(channel)) return;
    if (username) {
      this._channel_usernames[channel.name] = username;
    } else {
	    this._channel_usernames[channel.name] = 'anonymous';
    }
    channel.on('message', this._onMessage, this);
  },
  
  unsubscribe: function(channel) {
    if (channel === 'all') return this._channels.forEach(this.unsubscribe, this);
    if (!this._channels.member(channel)) return;
    this._channels.remove(channel);
    this._channel_usernames[channel.name] = null;
    channel.stopObserving('message', this._onMessage, this);
  },
  
  connect: function(callback) {
    this.callback(callback);
    if (this._connected) return;
    
    this._connected = true;
    
    if (this._deletionTimeout) {
      clearTimeout(this._deletionTimeout);
      delete this._deletionTimeout;
    }
    
    this._beginDeliveryTimeout();
    this._beginConnectionTimeout();
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
  
  _beginDeliveryTimeout: function() {
    if (this._deliveryTimeout || !this._connected || this._inbox.isEmpty())
      return;
    
    var self = this;
    this._deliveryTimeout = setTimeout(function () { self.flush() },
                                       this.MAX_DELAY * 1000);
  },
  
  _beginConnectionTimeout: function() {
    if (this._connectionTimeout || !this._connected)
      return;
    
    var self = this;
    this._connectionTimeout = setTimeout(function() { self.flush() },
                                         this.getTimeout() * 1000);
  },
  
  _releaseConnection: function() {
    if (this._connectionTimeout) {
      clearTimeout(this._connectionTimeout);
      delete this._connectionTimeout;
    }
    
    if (this._deliveryTimeout) {
      clearTimeout(this._deliveryTimeout);
      delete this._deliveryTimeout;
    }
    
    this._connected = false;
    this._scheduleForDeletion();
  },
  
  _scheduleForDeletion: function() {
    if (this._deletionTimeout) return;
    var self = this;
    
    this._deletionTimeout = setTimeout(function() {
      self.fire('staleClient', self);
    }, 10 * 1000 * this.INTERVAL);
  }
});

Faye.extend(Faye.Connection.prototype, Faye.Deferrable);
Faye.extend(Faye.Connection.prototype, Faye.Observable);


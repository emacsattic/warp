#!/usr/bin/env coffee

http = require 'http'
url = require 'url'
WebSocketServer = new require('websocket').server

PORT = 8898

module.exports = class Warp
  constructor: (options = {}) ->
    @autoCloseClients = options.autoCloseClients
    @port   = options.port   or PORT
    @stdin  = process.stdin
    @stdout = process.stdout
    @stderr = process.stderr
    @sockets = {}
    @socketId = 0
    @mode = null
    @buf = []
    process.on 'SIGINT', @onSigint
    # process.on 'uncaughtException', (err) =>
    #   @stderr.write "error:uncaught_exception #{err}\n"

  # Static
  clientHtml: () => '''
<!DOCTYPE html>
<html>
  <head>
    <title>Warp</title>
    <style>
      * { margin:0; padding:0 }
      html {height:100%; overflow:hidden;}
      header { display:none; height:1.2em; overflow:hidden; border-bottom:solid 1px #bbb; }
      body { height:100%; width:100%; }
      iframe#warp-frame { height:100%; width:100%; border:0; }
      #closed-screen { display:none; height:100%; width:100%;
                       text-align: center; font-size: 3em; color: #fff;
                       position:absolute; left:0; top:0;
                       background-color:rgba(0,0,0,0.8); z-index: 99999;
                       padding: 2em;
                      }
    </style>
    <script src="/client.js"></script>
  </head>
  <body>
    <div id="closed-screen">Server not running :(</div>
    <header>
      Warp Client #<span id="client-id"/>
    </header>
    <iframe id="warp-frame" src="/content.html"/>
  </body>
</html>
'''

  clientJs: () => """
(function () {

var soc = new WebSocket('ws://' + location.host + '/', 'warp')
, nop = function(){}
, startupStack = []
;

startupStack.push(function() {
  soc.send(JSON.stringify({ type:'status', data:'start' }));

  var frame = document.getElementById('warp-frame');

  soc.onmessage = function(msg) {
    msg = JSON.parse(msg.data);
    console.log(msg.type, msg.data);
    switch (msg.type) {
      // case 'reload':
      //   frame.contentWindow.location.reload();
      //   break;
      case 'load':
      case 'url':
        frame.contentWindow.location.href = msg.data;
        break;
      case 'html':
        frame.contentDocument.documentElement.innerHTML = msg.data;
        document.title = frame.contentDocument.title
          //.replace(/<!doctype[^>]*>/i, '').replace(/<\\/?html[^>]*>/i, '');
        break;
      case 'client_id':
        document.getElementById('client-id').innerText = msg.data;
        break;
      default:
        soc.send(JSON.stringify({ type:'error', data:'unknown_type' }));
    }
  };

});

startupStack.push(nop);
soc.onopen = function() { startupStack.pop()(); };

startupStack.push(nop);
document.addEventListener('DOMContentLoaded', function() { startupStack.pop()(); });

startupStack.pop()();

soc.onclose = function() {
  if(#{@autoCloseClients}) { window.open('', '_self', ''); window.close(); }
  document.getElementById('closed-screen').setAttribute('style', 'display:block;');
};

}());
"""

  contentHtml: () => '''
<html>
  <body>
  </body>
</html>
'''

  onSigint: () =>
    @httpServer.close() if @httpServer
    process.exit()

  startServer: () =>
    @startHttpServer()
    @startWebSocketServer()
    @startStdinListener()

  startHttpServer: () =>
    @httpServer = http.createServer @handleHttpRequest
    @httpServer.listen @port
    console.log "start:lotalhost:#{@port}"

  handleHttpRequest: (req, res) =>
    switch url.parse(req.url).path
      when '/'
        res.writeHead 200, 'Content-Type': 'text/html'
        res.write @clientHtml(), 'utf-8'
      when '/content.html'
        res.writeHead 200, 'Content-Type': 'text/html'
        res.write @contentHtml(), 'utf-8'
      when '/client.js'
        res.writeHead 200, 'Content-Type': 'text/javascript'
        res.write @clientJs(), 'utf-8'
      else
        res.writeHead 404, 'Content-Type': 'text/plain'
        res.write '404 Not Found\n'

    res.end()

  # WebSocket
  startWebSocketServer: () =>
    @webSocketServer = new WebSocketServer
      httpServer: @httpServer

    @webSocketServer.on 'request', (req) =>
      webSocket = req.accept 'warp', req.origin

      # Make internal reference for client id
      id = @socketId++

      webSocket.send JSON.stringify
        type: 'client_id'
        data: id

      @sockets[id] = webSocket

      #From Client
      webSocket.on 'message', (msg) =>
        msg = JSON.parse(msg.utf8Data);
        @handleWebSocketMessage msg, id

      webSocket.on 'close', () =>
        delete @sockets[id]
        console.log "client_#{id}_status:closed"

  handleWebSocketMessage: (msg, id) =>
    console.log "client_#{id}_#{msg.type}:#{msg.data}"

  sendWebSocketMessage: (msg, id) =>
    if id
      @sockets[id].send (JSON.stringify msg)
    else
      for id, socket of @sockets
        socket.send (JSON.stringify msg)

  # STDIN
  startStdinListener: () =>
    @stdin.resume()
    @stdin.setEncoding 'utf8'
    @stdin.on 'data', @handleStdin
    @stdin.on 'end', @handleStdinEof

  handleStdin: (chunk) =>
    if /^\n+$/.test chunk
      # Split by "\n" only line
      data = @buf.join('')
      ## see data format here
      if /\S+/.test(data)
        @sendWebSocketMessage type: 'html', data: data
      @buf = []
    else
      @buf.push(chunk) if /\S+/.test(chunk)

  handleStdinEof: () =>

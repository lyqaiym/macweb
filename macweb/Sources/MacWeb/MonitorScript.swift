import Foundation

enum MonitorScript {
    static let source = #"""
    (function () {
      if (window.__macwebMonitorInstalled) return;
      window.__macwebMonitorInstalled = true;

      function send(msg) {
        try { window.webkit.messageHandlers.macweb.postMessage(msg); } catch (e) {}
      }

      function abs(u) {
        try { return new URL(u, document.baseURI).href; } catch (e) { return String(u); }
      }

      function kindFromInitiator(t) {
        switch (t) {
          case 'script': return 'script';
          case 'css': case 'link': return 'css';
          case 'img': case 'image': return 'image';
          case 'xmlhttprequest': return 'xhr';
          case 'fetch': return 'fetch';
          case 'font': return 'font';
          case 'audio': case 'video': case 'track': return 'media';
          case 'iframe': case 'frame': return 'frame';
          case 'navigation': return 'document';
          default: return 'other';
        }
      }

      function headerObj(headers) {
        var out = {};
        try {
          if (headers && typeof headers.forEach === 'function') {
            headers.forEach(function (v, k) { out[k] = String(v); });
          } else if (Array.isArray(headers)) {
            headers.forEach(function (p) { if (p && p.length >= 2) out[String(p[0])] = String(p[1]); });
          } else if (headers && typeof headers === 'object') {
            Object.keys(headers).forEach(function (k) { out[k] = String(headers[k]); });
          }
        } catch (e) {}
        return out;
      }

      function bodyText(body) {
        try {
          if (body == null) return '';
          if (typeof body === 'string') return body;
          if (typeof FormData !== 'undefined' && body instanceof FormData) return '[FormData]';
          if (typeof Blob !== 'undefined' && body instanceof Blob) return '[Blob ' + (body.type || '') + ']';
          if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) return body.toString();
          if (typeof ArrayBuffer !== 'undefined' && (body instanceof ArrayBuffer || ArrayBuffer.isView(body))) return '[binary]';
          return String(body);
        } catch (e) { return String(body); }
      }

      function truncateText(s, max) {
        if (typeof s !== 'string' || s.length <= max) return s;
        return s.slice(0, max) + '…[已截断，共 ' + s.length + ' 字符]';
      }

      function isTextualMime(mime) {
        var m = (mime || '').split(';')[0].toLowerCase();
        if (!m) return true;
        return m.indexOf('json') >= 0 || m.indexOf('text') >= 0 || m.indexOf('javascript') >= 0 ||
               m.indexOf('xml') >= 0 || m.indexOf('html') >= 0 || m.indexOf('x-www-form-urlencoded') >= 0 ||
               m.indexOf('svg') >= 0;
      }

      // 只读取前 limit 个字符，避免把整个响应体读进内存
      function readBodyPrefix(stream, limit, cb) {
        if (!stream) { cb(''); return; }
        var reader;
        try { reader = stream.getReader(); } catch (e) { cb(''); return; }
        var decoder = new TextDecoder();
        var acc = '';
        function pump() {
          reader.read().then(function (r) {
            if (r.done) {
              try { acc += decoder.decode(); } catch (e) {}
              cb(acc);
              return;
            }
            var chunk = '';
            try { chunk = decoder.decode(r.value, { stream: true }); } catch (e) {}
            acc += chunk;
            if (acc.length >= limit) {
              try { reader.cancel(); } catch (e) {}
              cb(acc.slice(0, limit) + '…[已截断]');
              return;
            }
            pump();
          }).catch(function () { cb(acc); });
        }
        pump();
      }

      // ---------- Resource / Navigation Timing ----------
      try {
        var po = new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (e) {
            var isNav = e.entryType === 'navigation';
            var msg = {
              source: 'timing',
              url: e.name,
              kind: isNav ? 'document' : kindFromInitiator(e.initiatorType),
              initiatorType: e.initiatorType || '',
              startTime: e.startTime,
              duration: e.duration,
              transferSize: e.transferSize || 0,
              encodedBodySize: e.encodedBodySize || 0,
              decodedBodySize: e.decodedBodySize || 0,
              protocol: e.nextHopProtocol || ''
            };
            if (isNav && typeof e.responseStatus === 'number') {
              msg.status = e.responseStatus;
            }
            send(msg);
          });
        });
        po.observe({ type: 'resource', buffered: true });
        try { po.observe({ type: 'navigation', buffered: true }); } catch (e) {}
      } catch (e) {}

      // ---------- fetch ----------
      try {
        var origFetch = window.fetch;
        if (origFetch) {
          window.fetch = function (input, init) {
            var url = '', method = 'GET';
            try {
              if (typeof input === 'string') {
                url = abs(input);
              } else if (input && typeof input.url === 'string') {
                url = abs(input.url);
                if (input.method) method = input.method;
              } else {
                url = abs(String(input));
              }
              if (init && init.method) method = init.method;
            } catch (e) { url = abs(String(input)); }
            method = (method || 'GET').toUpperCase();
            var reqHeaders = headerObj(init && init.headers);
            var reqBody = truncateText(bodyText(init && init.body), 100000);
            var start = performance.now();
            var p = origFetch.apply(this, arguments);
            Promise.resolve(p).then(function (res) {
              var mime = '';
              try { mime = res.headers ? (res.headers.get('content-type') || '') : ''; } catch (e) {}
              var respHeaders = headerObj(res.headers);
              var base = { source: 'req', kind: 'fetch', url: res.url || url, method: method,
                           status: res.status || 0, mimeType: mime, startTime: start, failed: !res.ok && res.status === 0,
                           requestHeaders: reqHeaders, requestBody: reqBody, responseHeaders: respHeaders };
              var clen = 0;
              try { clen = parseInt(res.headers.get('content-length') || '0', 10) || 0; } catch (e) {}
              if (isTextualMime(mime) && clen < 500000) {
                var clone = null;
                try { if (res.clone && res.body) clone = res.clone(); } catch (e) {}
                if (clone) {
                  readBodyPrefix(clone.body, 200000, function (body) {
                    base.responseBody = body;
                    send(base);
                  });
                } else {
                  base.responseBody = '';
                  send(base);
                }
              } else {
                base.responseBody = '';
                send(base);
              }
            }, function () {
              send({ source: 'req', kind: 'fetch', url: url, method: method,
                     status: 0, mimeType: '', startTime: start, failed: true,
                     requestHeaders: reqHeaders, requestBody: reqBody,
                     responseHeaders: {}, responseBody: '' });
            });
            return p;
          };
        }
      } catch (e) {}

      // ---------- XMLHttpRequest ----------
      try {
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.open = function (method, url) {
          this.__macweb = { method: (method || 'GET').toUpperCase(), url: abs(url), start: 0, headers: {}, body: '' };
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
          if (this.__macweb) { try { this.__macweb.headers[name] = String(value); } catch (e) {} }
          return origSetHeader.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function (body) {
          var self = this;
          if (self.__macweb) {
            self.__macweb.start = performance.now();
            self.__macweb.body = truncateText(bodyText(body), 100000);
          }
          self.addEventListener('loadend', function () {
            if (!self.__macweb) return;
            var info = self.__macweb;
            var status = 0, mime = '', respHeaders = {}, respBody = '';
            try {
              status = self.status || 0;
              mime = self.getResponseHeader('content-type') || '';
              var raw = self.getAllResponseHeaders();
              if (raw) {
                raw.trim().split(/[\r\n]+/).forEach(function (line) {
                  var i = line.indexOf(':');
                  if (i > 0) respHeaders[line.slice(0, i).trim()] = line.slice(i + 1).trim();
                });
              }
              if (isTextualMime(mime)) respBody = self.responseText || '';
            } catch (e) {}
            send({ source: 'req', kind: 'xhr', url: info.url, method: info.method,
                   status: status, mimeType: mime, startTime: info.start, failed: status === 0,
                   requestHeaders: info.headers, requestBody: info.body,
                   responseHeaders: respHeaders, responseBody: truncateText(respBody, 200000) });
          });
          return origSend.apply(this, arguments);
        };
      } catch (e) {}

      // ---------- WebSocket ----------
      try {
        var OrigWS = window.WebSocket;
        if (OrigWS) {
          var WrappedWS = function (url, protocols) {
            var start = performance.now();
            var ws = (protocols !== undefined) ? new OrigWS(url, protocols) : new OrigWS(url);
            send({ source: 'req', kind: 'websocket', url: abs(String(url)), method: 'WS',
                   status: 101, mimeType: '', startTime: start, failed: false });
            return ws;
          };
          WrappedWS.prototype = OrigWS.prototype;
          WrappedWS.CONNECTING = OrigWS.CONNECTING;
          WrappedWS.OPEN = OrigWS.OPEN;
          WrappedWS.CLOSING = OrigWS.CLOSING;
          WrappedWS.CLOSED = OrigWS.CLOSED;
          window.WebSocket = WrappedWS;
        }
      } catch (e) {}
    })();
    """#
}

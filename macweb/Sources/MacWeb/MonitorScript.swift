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
            var start = performance.now();
            var p = origFetch.apply(this, arguments);
            Promise.resolve(p).then(function (res) {
              var mime = '';
              try { mime = res.headers ? (res.headers.get('content-type') || '') : ''; } catch (e) {}
              send({ source: 'req', kind: 'fetch', url: res.url || url, method: method,
                     status: res.status || 0, mimeType: mime, startTime: start, failed: !res.ok && res.status === 0 });
            }, function () {
              send({ source: 'req', kind: 'fetch', url: url, method: method,
                     status: 0, mimeType: '', startTime: start, failed: true });
            });
            return p;
          };
        }
      } catch (e) {}

      // ---------- XMLHttpRequest ----------
      try {
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
          this.__macweb = { method: (method || 'GET').toUpperCase(), url: abs(url), start: 0 };
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
          var self = this;
          if (self.__macweb) self.__macweb.start = performance.now();
          self.addEventListener('loadend', function () {
            if (!self.__macweb) return;
            var info = self.__macweb;
            var status = 0, mime = '';
            try { status = self.status || 0; mime = self.getResponseHeader('content-type') || ''; } catch (e) {}
            send({ source: 'req', kind: 'xhr', url: info.url, method: info.method,
                   status: status, mimeType: mime, startTime: info.start, failed: status === 0 });
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

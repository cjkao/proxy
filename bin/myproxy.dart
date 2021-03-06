// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
library myprox;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'dart:async';

/// A handler that proxies requests to [url].
///
/// To generate the proxy request, this concatenates [url] and [Request.url].
/// This means that if the handler mounted under `/documentation` and [url] is
/// `http://example.com/docs`, a request to `/documentation/tutorials`
/// will be proxied to `http://example.com/docs/tutorials`.
///
/// [client] is used internally to make HTTP requests. It defaults to a
/// `dart:io`-based client.
///
/// [proxyName] is used in headers to identify this proxy. It should be a valid
/// HTTP token or a hostname. It defaults to `shelf_proxy`.
Handler proxyHandler(url, {http.Client client, String proxyName}) {
  if (url is String) url = Uri.parse(url);
  if (client == null) client = new http.Client();
  if (proxyName == null) proxyName = 'shelf_proxy';

  return (serverRequest) {
    // TODO(nweiz): Support WebSocket requests.

    // TODO(nweiz): Handle TRACE requests correctly. See
    // http://www.w3.org/Protocols/rfc2616/rfc2616-sec9.html#sec9.8
    var requestUrl = url.resolve(serverRequest.url.toString());
    var clientRequest = new http.StreamedRequest(serverRequest.method, requestUrl);
    clientRequest.followRedirects = false;
    clientRequest.headers.addAll(serverRequest.headers);
    clientRequest.headers['Host'] = url.authority;
    clientRequest.headers['xx'] = 'zz';
    clientRequest.headers['cookie']="${clientRequest.headers['cookie']} ; a=b";
    // Add a Via header. See
    // http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.45
    _addHeader(clientRequest.headers, 'via', '${serverRequest.protocolVersion} $proxyName');

    store(serverRequest.read(), clientRequest.sink);
    return client.send(clientRequest).then((clientResponse) {
      // Add a Via header. See
      // http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.45
      _addHeader(clientResponse.headers, 'via', '1.1 $proxyName');
      print(serverRequest.headers['referer']);
      addCorsHeader(clientResponse.headers, serverRequest.headers['referer']);

      // Remove the transfer-encoding since the body has already been decoded by
      // [client].
      clientResponse.headers.remove('transfer-encoding');

      // If the original response was gzipped, it will be decoded by [client]
      // and we'll have no way of knowing its actual content-length.
      if (clientResponse.headers['content-encoding'] == 'gzip') {
        clientResponse.headers.remove('content-encoding');
        clientResponse.headers.remove('content-length');

        // Add a Warning header. See
        // http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.2
        _addHeader(clientResponse.headers, 'warning', '214 $proxyName "GZIP decoded"');
      }

      // Make sure the Location header is pointing to the proxy server rather
      // than the destination server, if possible.
      if (clientResponse.isRedirect && clientResponse.headers.containsKey('location')) {
        var location = requestUrl.resolve(clientResponse.headers['location']).toString();
        if (p.url.isWithin(url.toString(), location)) {
          clientResponse.headers['location'] = '/' + p.url.relative(location, from: url.toString());
        } else {
          clientResponse.headers['location'] = location;
        }
      }

      return new Response(clientResponse.statusCode, body: clientResponse.stream, headers: clientResponse.headers);
    });
  };
}

// TODO(nweiz): use built-in methods for this when http and shelf support them.
/// Add a header with [name] and [value] to [headers], handling existing headers
/// gracefully.
void addCorsHeader(Map<String, String> headers, String referer) {
  var uri= Uri.parse(referer);

  headers['Access-Control-Allow-Origin'] = 'http://${uri.host}:${uri.port}';
  headers['Access-Control-Allow-Methods'] = "POST, GET, OPTIONS";
  headers['Access-Control-Allow-Headers'] = "X-PINGOTHER";
  headers['Access-Control-Max-Age'] ='1728000';
}

void _addHeader(Map<String, String> headers, String name, String value) {
  if (headers.containsKey(name)) {
    headers[name] += ', $value';
  } else {
    headers[name] = value;
  }
}

// TODO(nweiz): remove this when issue 7786 is fixed.
/// Pipes all data and errors from [stream] into [sink].
///
/// When [stream] is done, the returned [Future] is completed and [sink] is
/// closed if [closeSink] is true.
///
/// When an error occurs on [stream], that error is passed to [sink]. If
/// [cancelOnError] is true, [Future] will be completed successfully and no
/// more data or errors will be piped from [stream] to [sink]. If
/// [cancelOnError] and [closeSink] are both true, [sink] will then be
/// closed.
Future store(Stream stream, EventSink sink, {bool cancelOnError: true, bool closeSink: true}) {
  var completer = new Completer();
  stream.listen(sink.add, onError: (e, stackTrace) {
    sink.addError(e, stackTrace);
    if (cancelOnError) {
      completer.complete();
      if (closeSink) sink.close();
    }
  }, onDone: () {
    if (closeSink) sink.close();
    completer.complete();
  }, cancelOnError: cancelOnError);
  return completer.future;
}

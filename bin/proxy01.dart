import 'package:shelf/shelf_io.dart' as shelf_io;
import 'myproxy.dart';
void main() {
  shelf_io.serve(proxyHandler("https://www.dartlang.org"), 'localhost', 8080)
      .then((server) {
    print('Proxying at http://${server.address.host}:${server.port}');
  });
}

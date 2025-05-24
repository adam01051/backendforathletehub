import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';
import 'dart:convert';

class BackendService {
  final PostgreSQLConnection _connection;

  BackendService(this._connection);

  Future<Response> loginHandler(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body);
      final email = data['email'] as String?;
      final password = data['password'] as String?;

      if (email == null || password == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Email and password are required'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      print('Received login request: email=$email');

      final results = await _connection.query(
        'SELECT * FROM users WHERE email = @email LIMIT 1',
        substitutionValues: {'email': email},
      );

      if (results.isEmpty) {
        return Response(401,
            body: jsonEncode({'error': 'Email not found'}),
            headers: {'Content-Type': 'application/json'});
      }

      final user = results.first;
      final storedPassword = user[3]; // Password is 4th column (index 3)

      if (storedPassword != password) {
        return Response(401,
            body: jsonEncode({'error': 'Incorrect password'}),
            headers: {'Content-Type': 'application/json'});
      }

      return Response.ok(
        jsonEncode({
          'message': 'Login successful',
          'user': {
            'name': user[1],
            'email': user[2],
            'sport': user[4],
          },
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('Error during login: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Server error: $e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Future<Response> registerHandler(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body);
      final name = data['name'] as String?;
      final email = data['email'] as String?;
      final password = data['password'] as String?;
      final sport = data['sport'] as String?;

      if (name == null || email == null || password == null || sport == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'All fields are required'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Check if email already exists
      final checkResults = await _connection.query(
        'SELECT COUNT(*) FROM users WHERE email = @email',
        substitutionValues: {'email': email},
      );
      if (checkResults.first[0] > 0) {
        return Response(409,
            body: jsonEncode({'error': 'Email already registered'}),
            headers: {'Content-Type': 'application/json'});
      }

      await _connection.execute(
        '''
        INSERT INTO users (name, email, password, sport)
        VALUES (@name, @email, @password, @sport)
        ''',
        substitutionValues: {
          'name': name,
          'email': email,
          'password': password,
          'sport': sport,
        },
      );

      return Response.ok(
        jsonEncode({'message': 'Registration successful'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('Error during registration: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Server error: $e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Router get router {
    final router = Router();
    router.post('/api/login', loginHandler);
    router.post(
        '/api/register', registerHandler); // Ensure this line is present
    return router;
  }
}

void main() async {
  final connection = PostgreSQLConnection(
    '127.0.0.1',
    5432,
    'flutter',
    username: 'postgres',
    password: '4909770',
    timeoutInSeconds: 30,
  );

  print('Connecting to database...');
  try {
    await connection.open();
    print('Database connected successfully');
  } catch (e) {
    print('Failed to connect to database: $e');
    exit(1);
  }

  final service = BackendService(connection);
  final handler =
      const Pipeline().addMiddleware(logRequests()).addHandler(service.router);
  final server = await shelf_io.serve(handler, '0.0.0.0', 8080);
  print('Server running on ${server.address.host}:${server.port}');
}

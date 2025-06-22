import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf_multipart/form_data.dart';
import 'dart:convert';
import 'package:path/path.dart' as path;

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

  Future<Response> uploadVideoHandler(Request request) async {
    try {
      // Check if the request is multipart/form-data
      final contentType = request.headers['content-type'];
      if (contentType == null ||
          !contentType.toLowerCase().contains('multipart/form-data')) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Request must be multipart/form-data'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final userId = int.tryParse(request.headers['user-id'] ?? '');
      if (userId == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'User ID is required in headers'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Check if user exists
      final userCheck = await _connection.query(
        'SELECT COUNT(*) FROM users WHERE id = @user_id',
        substitutionValues: {'user_id': userId},
      );
      if (userCheck.first[0] == 0) {
        return Response(404,
            body: jsonEncode({'error': 'User not found'}),
            headers: {'Content-Type': 'application/json'});
      }

      // Parse multipart form data
      FormData? videoPart;
      await for (final part in request.multipartFormData) {
        if (part.name == 'video') {
          videoPart = part;
          break;
        }
      }

      if (videoPart == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Video file is required'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Read video data into bytes
      final videoData = await videoPart.part.readBytes();
      final originalFilename = videoPart.filename ?? 'unknown_video.mp4';
      final size = videoData.length;

      print(
          'Uploading video: user_id=$userId, filename=$originalFilename, size=$size bytes');

      // Sanitize filename to avoid invalid characters
      final sanitizedFilename = path
              .basenameWithoutExtension(originalFilename)
              .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_') +
          path.extension(originalFilename);
      print('Sanitized filename: $sanitizedFilename');

      // Save video to filesystem
      final uploadDir = Directory('uploads');
      if (!await uploadDir.exists()) {
        await uploadDir.create(recursive: true);
        print('Created uploads directory at ${uploadDir.path}');
      }

      // Check disk space with better error handling
      int availableKB = 0;
      try {
        final diskSpace = await Process.run('df', ['-k', uploadDir.path]);
        if (diskSpace.exitCode != 0) {
          print('Failed to check disk space: ${diskSpace.stderr}');
          // Skip disk space check if df fails
        } else {
          final lines = diskSpace.stdout
              .split('\n')
              .where((String line) => line.trim().isNotEmpty)
              .toList();
          print('df output: $lines');
          if (lines.length < 2) {
            print('df output too short, skipping disk space check');
          } else {
            final columns = lines[1].split(RegExp(r'\s+'));
            if (columns.length < 4) {
              print(
                  'df output columns too few: $columns, skipping disk space check');
            } else {
              availableKB = int.parse(columns[3]);
              final sizeKB = size ~/ 1024;
              print(
                  'Available disk space: $availableKB KB, Required: $sizeKB KB');
              if (availableKB < sizeKB) {
                return Response.internalServerError(
                  body: jsonEncode({'error': 'Insufficient disk space'}),
                  headers: {'Content-Type': 'application/json'},
                );
              }
            }
          }
        }
      } catch (e) {
        print('Error checking disk space, skipping: $e');
      }

      final filePath = 'uploads/$sanitizedFilename';
      final file = File(filePath);
      await file.writeAsBytes(videoData);
      print('Video saved to $filePath');

      // Insert file path into database
      await _connection.execute(
        '''
        INSERT INTO videos (user_id, file_path, filename, size)
        VALUES (@user_id, @file_path, @filename, @size)
        ''',
        substitutionValues: {
          'user_id': userId,
          'file_path': filePath,
          'filename': sanitizedFilename,
          'size': size,
        },
      );
      print('Database entry created for $sanitizedFilename');

      return Response.ok(
        jsonEncode({'message': 'Video uploaded successfully'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('Error during video upload (outer catch): $e');
      if (e is PostgreSQLException) {
        print(
            'PostgreSQL Error: ${e.message}, Code: ${e.code}, Detail: ${e.detail}');
      } else {
        print('General exception stack trace: ${e.toString()}');
      }
      return Response.internalServerError(
        body: jsonEncode({'error': 'Server error: $e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Router get router {
    final router = Router();
    router.post('/api/login', loginHandler);
    router.post('/api/register', registerHandler);
    router.post('/api/upload-video', uploadVideoHandler);
    return router;
  }
}
//just  checking  push to github

void main() async {
  final connection = PostgreSQLConnection(
    '127.0.0.1',
    5432,
    'flutter',
    username: 'postgres',
    password: '4909770',
    timeoutInSeconds: 60,
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


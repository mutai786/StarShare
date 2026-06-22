import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseService {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;

    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    String path = join(
      await getDatabasesPath(),
      'starshare.db',
    );

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE transfers(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fileName TEXT,
            fileSize INTEGER,
            direction TEXT,
            deviceIp TEXT,
            timestamp TEXT
          )
        ''');
      },
    );
  }
}// TODO Implement this library.
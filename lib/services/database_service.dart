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
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE transfers(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fileName TEXT,
            fileSize INTEGER,
            direction TEXT,
            deviceIp TEXT,
            timestamp TEXT,
            filePath TEXT
          )
        ''');
        await _createNotificationsTable(db);
      },
      // Existing installs keep their history; each step only adds things.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE transfers ADD COLUMN filePath TEXT');
        }
        if (oldVersion < 3) {
          await _createNotificationsTable(db);
        }
      },
    );
  }

  static Future<void> _createNotificationsTable(Database db) async {
    await db.execute('''
      CREATE TABLE notifications(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        body TEXT,
        createdAt INTEGER,
        isRead INTEGER DEFAULT 0,
        filePath TEXT
      )
    ''');
  }
}

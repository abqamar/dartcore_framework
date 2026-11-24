import 'package:dartcore_migrations/dartcore_migrations.dart';

class UserSeeder extends Seeder {
  @override
  Future<void> run() async {
    await db.table('users').insertMany([
      {
        'name': 'Demo',
        'email': 'demo@example.com',
        'password': r'not-a-real-hash',
      },
    ]);
  }
}

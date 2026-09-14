// lib/main.dart
// ==============================================================================
// 100% OFFLINE POLIO ROUTE NAVIGATOR
// Features:
// 1. 100% Offline SQLite database with schema for routes & vaccination checkpoints
// 2. 1D/2D Kalman Filter algorithm for mitigating urban/rural GPS multipath drift
// 3. Background foreground task tracking via flutter_foreground_task
// 4. Wakelock to prevent screen sleep during active vaccination rounds
// 5. Local assets (assets/developer.jpg) with zero network dependency
// ==============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// -----------------------------------------------------------------------------
// Top-Level Background Task Handler Callback
// -----------------------------------------------------------------------------
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(PolioLocationTaskHandler());
}

class PolioLocationTaskHandler extends TaskHandler {
  final KalmanLatLong _kalman = KalmanLatLong(qMetresPerSecond: 3.0);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Initialize background task
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );

      _kalman.process(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: pos.accuracy,
        timestampMs: timestamp.millisecondsSinceEpoch,
      );

      // Save to SQLite
      await DatabaseHelper.instance.insertWaypoint(
        rawLat: pos.latitude,
        rawLng: pos.longitude,
        filteredLat: _kalman.lat,
        filteredLng: _kalman.lng,
        accuracy: pos.accuracy,
        speed: pos.speed,
        timestamp: timestamp.toIso8601String(),
      );

      // Update notification with live distance/status
      FlutterForegroundTask.updateService(
        notificationTitle: 'Polio Campaign Route Active',
        notificationText: 'Tracking: ${_kalman.lat.toStringAsFixed(5)}, ${_kalman.lng.toStringAsFixed(5)}',
      );
    } catch (_) {
      // 100% offline - ignore intermittent GPS read timeouts
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Cleanup background resources
  }
}

// -----------------------------------------------------------------------------
// 1D/2D Kalman Filter Implementation for GPS Drift Smoothing
// -----------------------------------------------------------------------------
class KalmanLatLong {
  final double qMetresPerSecond;
  long? _timestampMs;
  double _lat = 0.0;
  double _lng = 0.0;
  double _variance = -1.0; // P error covariance

  KalmanLatLong({this.qMetresPerSecond = 3.0});

  double get lat => _lat;
  double get lng => _lng;
  double get accuracy => math.sqrt(_variance);
  bool get isInitialized => _variance > 0;

  void reset() {
    _variance = -1.0;
    _timestampMs = null;
  }

  void process({
    required double lat,
    required double lng,
    required double accuracy,
    required int timestampMs,
  }) {
    if (accuracy < 1.0) accuracy = 1.0;

    if (_variance < 0) {
      // First point initialization
      _timestampMs = timestampMs;
      _lat = lat;
      _lng = lng;
      _variance = accuracy * accuracy;
    } else {
      final long timeDelta = timestampMs - (_timestampMs ?? timestampMs);
      if (timeDelta > 0) {
        // State Prediction: estimate variance increases with time delta
        _variance += (timeDelta / 1000.0) * qMetresPerSecond * qMetresPerSecond;
        _timestampMs = timestampMs;
      }

      // Kalman Gain: K = P / (P + R)
      final double measurementVariance = accuracy * accuracy;
      final double k = _variance / (_variance + measurementVariance);

      // Measurement Update
      _lat += k * (lat - _lat);
      _lng += k * (lng - _lng);

      // Covariance Update: P = (1 - K) * P
      _variance = (1.0 - k) * _variance;
    }
  }
}

typedef long = int;

// -----------------------------------------------------------------------------
// 100% Offline SQLite Database Helper
// -----------------------------------------------------------------------------
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('polio_route_navigator.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE waypoints (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        raw_lat REAL NOT NULL,
        raw_lng REAL NOT NULL,
        filtered_lat REAL NOT NULL,
        filtered_lng REAL NOT NULL,
        accuracy REAL NOT NULL,
        speed REAL NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE checkpoints (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        house_number TEXT NOT NULL,
        children_vaccinated INTEGER NOT NULL,
        status TEXT NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        notes TEXT,
        timestamp TEXT NOT NULL
      )
    ''');
  }

  Future<int> insertWaypoint({
    required double rawLat,
    required double rawLng,
    required double filteredLat,
    required double filteredLng,
    required double accuracy,
    required double speed,
    required String timestamp,
  }) async {
    final db = await database;
    return await db.insert('waypoints', {
      'raw_lat': rawLat,
      'raw_lng': rawLng,
      'filtered_lat': filteredLat,
      'filtered_lng': filteredLng,
      'accuracy': accuracy,
      'speed': speed,
      'timestamp': timestamp,
    });
  }

  Future<int> insertCheckpoint({
    required String houseNumber,
    required int childrenVaccinated,
    required String status,
    required double latitude,
    required double longitude,
    String? notes,
  }) async {
    final db = await database;
    return await db.insert('checkpoints', {
      'house_number': houseNumber,
      'children_vaccinated': childrenVaccinated,
      'status': status,
      'latitude': latitude,
      'longitude': longitude,
      'notes': notes ?? '',
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getWaypoints({int limit = 100}) async {
    final db = await database;
    return await db.query('waypoints', orderBy: 'id DESC', limit: limit);
  }

  Future<List<Map<String, dynamic>>> getCheckpoints() async {
    final db = await database;
    return await db.query('checkpoints', orderBy: 'id DESC');
  }

  Future<int> getWaypointCount() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM waypoints'),
    );
    return count ?? 0;
  }

  Future<int> getTotalVaccinated() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT SUM(children_vaccinated) FROM checkpoints'),
    );
    return count ?? 0;
  }

  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('waypoints');
    await db.delete('checkpoints');
  }
}

// -----------------------------------------------------------------------------
// Main Entry Point
// -----------------------------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set preferred portrait orientation for fieldwork efficiency
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  _initForegroundTask();

  runApp(const PolioNavigatorApp());
}

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'polio_route_channel',
      channelName: 'Polio Campaign Navigation Service',
      channelDescription: 'Maintains background location tracking for health workers.',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(3000),
      autoRunOnBoot: false,
      allowWakeLock: true,
    ),
  );
}

// -----------------------------------------------------------------------------
// Root Application
// -----------------------------------------------------------------------------
class PolioNavigatorApp extends StatelessWidget {
  const PolioNavigatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Polio Route Navigator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0284C7),
          primary: const Color(0xFF0284C7),
          secondary: const Color(0xFF0EA5E9),
          surface: const Color(0xFFF8FAFC),
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: true,
          backgroundColor: Color(0xFF0284C7),
          foregroundColor: Colors.white,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// -----------------------------------------------------------------------------
// Home Screen
// -----------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  bool _isTracking = false;
  bool _wakeLockEnabled = true;
  StreamSubscription<Position>? _positionStream;
  final KalmanLatLong _kalmanFilter = KalmanLatLong(qMetresPerSecond: 3.0);

  Position? _latestRawPosition;
  double? _latestFilteredLat;
  double? _latestFilteredLng;
  double _totalDistanceMeters = 0.0;
  int _waypointCount = 0;
  int _totalVaccinatedCount = 0;
  List<Map<String, dynamic>> _checkpoints = [];

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _loadStoredStats();
    _initWakeLock();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    if (_wakeLockEnabled) {
      WakelockPlus.disable();
    }
    super.dispose();
  }

  Future<void> _initWakeLock() async {
    await WakelockPlus.enable();
    setState(() => _wakeLockEnabled = true);
  }

  Future<void> _toggleWakeLock() async {
    final newState = !_wakeLockEnabled;
    await WakelockPlus.toggle(enable: newState);
    setState(() => _wakeLockEnabled = newState);
  }

  Future<void> _checkPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
  }

  Future<void> _loadStoredStats() async {
    final wpCount = await DatabaseHelper.instance.getWaypointCount();
    final vCount = await DatabaseHelper.instance.getTotalVaccinated();
    final checks = await DatabaseHelper.instance.getCheckpoints();

    if (mounted) {
      setState(() {
        _waypointCount = wpCount;
        _totalVaccinatedCount = vCount;
        _checkpoints = checks;
      });
    }
  }

  Future<void> _toggleTracking() async {
    if (_isTracking) {
      await _stopTracking();
    } else {
      await _startTracking();
    }
  }

  Future<void> _startTracking() async {
    final hasPermission = await Geolocator.checkPermission();
    if (hasPermission == LocationPermission.denied ||
        hasPermission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission is required for offline tracking.')),
      );
      return;
    }

    // Start Foreground Service
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Polio Route Tracking Active',
      notificationText: 'Logging immunization pathway offline...',
      callback: startCallback,
    );

    // Start active GPS stream with Kalman filtering
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 3, // meters
    );

    _kalmanFilter.reset();

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) async {
        final prevLat = _latestFilteredLat;
        final prevLng = _latestFilteredLng;

        _kalmanFilter.process(
          lat: position.latitude,
          lng: position.longitude,
          accuracy: position.accuracy,
          timestampMs: position.timestamp.millisecondsSinceEpoch,
        );

        final filteredLat = _kalmanFilter.lat;
        final filteredLng = _kalmanFilter.lng;

        if (prevLat != null && prevLng != null) {
          final stepDistance = Geolocator.distanceBetween(
            prevLat,
            prevLng,
            filteredLat,
            filteredLng,
          );
          _totalDistanceMeters += stepDistance;
        }

        await DatabaseHelper.instance.insertWaypoint(
          rawLat: position.latitude,
          rawLng: position.longitude,
          filteredLat: filteredLat,
          filteredLng: filteredLng,
          accuracy: position.accuracy,
          speed: position.speed,
          timestamp: position.timestamp.toIso8601String(),
        );

        if (mounted) {
          setState(() {
            _latestRawPosition = position;
            _latestFilteredLat = filteredLat;
            _latestFilteredLng = filteredLng;
            _waypointCount++;
          });
        }
      },
    );

    setState(() => _isTracking = true);
  }

  Future<void> _stopTracking() async {
    await _positionStream?.cancel();
    _positionStream = null;
    await FlutterForegroundTask.stopService();

    setState(() => _isTracking = false);
    _loadStoredStats();
  }

  void _showAddCheckpointDialog() {
    final houseCtrl = TextEditingController();
    final childCtrl = TextEditingController(text: '1');
    String status = 'Vaccinated';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Mark House Checkpoint'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: houseCtrl,
                  decoration: const InputDecoration(
                    labelText: 'House / Target Code',
                    hintText: 'e.g. H-104, Block B',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: childCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Children (0-5 yrs)',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: status,
                  items: const [
                    DropdownMenuItem(value: 'Vaccinated', child: Text('Vaccinated (Green)')),
                    DropdownMenuItem(value: 'Absent', child: Text('Absent / Locked')),
                    DropdownMenuItem(value: 'Refused', child: Text('Refusal Case')),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => status = val);
                  },
                  decoration: const InputDecoration(labelText: 'Visit Status'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final house = houseCtrl.text.trim();
                final count = int.tryParse(childCtrl.text) ?? 0;
                final lat = _latestFilteredLat ?? _latestRawPosition?.latitude ?? 0.0;
                final lng = _latestFilteredLng ?? _latestRawPosition?.longitude ?? 0.0;

                if (house.isNotEmpty) {
                  await DatabaseHelper.instance.insertCheckpoint(
                    houseNumber: house,
                    childrenVaccinated: count,
                    status: status,
                    latitude: lat,
                    longitude: lng,
                  );
                  Navigator.pop(ctx);
                  _loadStoredStats();
                }
              },
              child: const Text('Save Local Checkpoint'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Polio Route Navigator'),
        actions: [
          IconButton(
            tooltip: 'Wakelock Screen Keep-On',
            icon: Icon(
              _wakeLockEnabled ? Icons.screen_lock_portrait : Icons.screen_lock_rotation,
              color: _wakeLockEnabled ? Colors.yellowAccent : Colors.white70,
            ),
            onPressed: _toggleWakeLock,
          ),
          IconButton(
            tooltip: 'Clear Offline Route Data',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Clear All Local Route Data?'),
                  content: const Text('This will purge all local SQLite waypoints and checkpoints.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear Database')),
                  ],
                ),
              );
              if (confirm == true) {
                await DatabaseHelper.instance.clearAllData();
                _totalDistanceMeters = 0.0;
                _loadStoredStats();
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 1,
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(30),
                        child: Image.asset(
                          'assets/developer.jpg',
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              width: 60,
                              height: 60,
                              color: const Color(0xFFE0F2FE),
                              child: const Icon(Icons.person, color: Color(0xFF0284C7), size: 36),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Field Vaccination Team #04',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const Text(
                              '100% Offline Mode • SQLite Active',
                              style: TextStyle(color: Colors.green, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              'Wakelock: ${_wakeLockEnabled ? "ON (Screen Stays Awake)" : "OFF"}',
                              style: const TextStyle(color: Colors.black54, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildMetricCard(
                      label: 'Distance (KM)',
                      value: (_totalDistanceMeters / 1000.0).toStringAsFixed(2),
                      icon: Icons.directions_walk,
                      color: const Color(0xFF0284C7),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildMetricCard(
                      label: 'Waypoints',
                      value: '$_waypointCount',
                      icon: Icons.timeline,
                      color: const Color(0xFF0D9488),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildMetricCard(
                      label: 'Vaccinated',
                      value: '$_totalVaccinatedCount',
                      icon: Icons.child_care,
                      color: const Color(0xFF16A34A),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 1,
                color: const Color(0xFFF1F5F9),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Kalman Filter Drift Correction',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: _isTracking ? Colors.green.shade100 : Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _isTracking ? 'FILTERING LIVE' : 'STANDBY',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: _isTracking ? Colors.green.shade800 : Colors.black54,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 16),
                      Text(
                        'Raw GPS: ${_latestRawPosition?.latitude.toStringAsFixed(6) ?? "--"}, ${_latestRawPosition?.longitude.toStringAsFixed(6) ?? "--"}',
                        style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: Colors.black87),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Filtered: ${_latestFilteredLat?.toStringAsFixed(6) ?? "--"}, ${_latestFilteredLng?.toStringAsFixed(6) ?? "--"}',
                        style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: Color(0xFF0284C7), fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Sensor Accuracy Variance: ${_latestRawPosition?.accuracy.toStringAsFixed(1) ?? "--"}m',
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _toggleTracking,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isTracking ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: Icon(_isTracking ? Icons.stop : Icons.play_arrow),
                label: Text(
                  _isTracking ? 'STOP ROUTE TRACKING' : 'START OFFLINE TRACKING',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _showAddCheckpointDialog,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.add_location_alt),
                label: const Text('MARK HOUSE CHECKPOINT'),
              ),
              const SizedBox(height: 24),
              const Text(
                'Recent Checkpoints (Local SQLite)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (_checkpoints.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: const Center(
                    child: Text('No checkpoints logged yet. Tap "Mark House Checkpoint" to begin.'),
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _checkpoints.length,
                  itemBuilder: (ctx, i) {
                    final item = _checkpoints[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: item['status'] == 'Vaccinated'
                              ? Colors.green.shade100
                              : Colors.amber.shade100,
                          child: Icon(
                            item['status'] == 'Vaccinated' ? Icons.check : Icons.warning_amber,
                            color: item['status'] == 'Vaccinated' ? Colors.green : Colors.amber.shade900,
                          ),
                        ),
                        title: Text('House: ${item['house_number']}'),
                        subtitle: Text('Children: ${item['children_vaccinated']} • Status: ${item['status']}'),
                        trailing: Text(
                          DateFormat('HH:mm').format(DateTime.tryParse(item['timestamp']) ?? DateTime.now()),
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCard({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

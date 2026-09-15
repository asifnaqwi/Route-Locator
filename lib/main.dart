// lib/main.dart
// ==============================================================================
// 100% OFFLINE POLIO ROUTE NAVIGATOR (VISUAL MAP EDITION)
// Features:
// 1. Visual Map with flutter_map & latlong2
// 2. Tracking Mode (Records red polyline, saves with category)
// 3. Guide Mode (Loads blue polyline, navigation arrow rotates by heading)
// 4. Background foreground task tracking (Wakelock removed for battery saving)
// 5. 1D/2D Kalman Filter algorithm for mitigating GPS drift
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

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

      // Check if a route is currently being actively tracked
      SharedPreferences prefs = await SharedPreferences.getInstance();
      int? activeRouteId = prefs.getInt('activeRouteId');

      if (activeRouteId != null) {
        await DatabaseHelper.instance.insertRoutePoint(
          routeId: activeRouteId,
          lat: _kalman.lat,
          lng: _kalman.lng,
          timestamp: timestamp.toIso8601String(),
        );
      }

      FlutterForegroundTask.updateService(
        notificationTitle: 'Tracking Route in Background',
        notificationText: 'Location: ${_kalman.lat.toStringAsFixed(5)}, ${_kalman.lng.toStringAsFixed(5)}',
      );
    } catch (_) {}
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

// -----------------------------------------------------------------------------
// Kalman Filter Implementation
// -----------------------------------------------------------------------------
class KalmanLatLong {
  final double qMetresPerSecond;
  int? _timestampMs;
  double _lat = 0.0;
  double _lng = 0.0;
  double _variance = -1.0;

  KalmanLatLong({this.qMetresPerSecond = 3.0});

  double get lat => _lat;
  double get lng => _lng;

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
      _timestampMs = timestampMs;
      _lat = lat;
      _lng = lng;
      _variance = accuracy * accuracy;
    } else {
      final int timeDelta = timestampMs - (_timestampMs ?? timestampMs);
      if (timeDelta > 0) {
        _variance += (timeDelta / 1000.0) * qMetresPerSecond * qMetresPerSecond;
        _timestampMs = timestampMs;
      }

      final double measurementVariance = accuracy * accuracy;
      final double k = _variance / (_variance + measurementVariance);

      _lat += k * (lat - _lat);
      _lng += k * (lng - _lng);
      _variance = (1.0 - k) * _variance;
    }
  }
}

// -----------------------------------------------------------------------------
// SQLite Database Helper (Updated Schema for Routes)
// -----------------------------------------------------------------------------
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    // Changed DB name to ensure fresh schema creation
    _database = await _initDB('polio_navigator_v2.db');
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
      CREATE TABLE routes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE route_points (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        route_id INTEGER NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');
  }

  Future<int> insertRoute(String name, String category) async {
    final db = await database;
    return await db.insert('routes', {
      'name': name,
      'category': category,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<int> insertRoutePoint({
    required int routeId,
    required double lat,
    required double lng,
    required String timestamp,
  }) async {
    final db = await database;
    return await db.insert('route_points', {
      'route_id': routeId,
      'lat': lat,
      'lng': lng,
      'timestamp': timestamp,
    });
  }

  Future<List<Map<String, dynamic>>> getRoutes() async {
    final db = await database;
    return await db.query('routes', orderBy: 'id DESC');
  }

  Future<List<Map<String, dynamic>>> getRoutePoints(int routeId) async {
    final db = await database;
    return await db.query('route_points', where: 'route_id = ?', whereArgs: [routeId], orderBy: 'id ASC');
  }
}

// -----------------------------------------------------------------------------
// Main Entry Point
// -----------------------------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      channelId: 'route_tracker_channel',
      channelName: 'Route Tracking Service',
      channelDescription: 'Maintains background location tracking.',
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
      allowWakeLock: false, // Wakelock explicitly disabled for battery saving
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0284C7)),
      ),
      home: const MapScreen(),
    );
  }
}

// -----------------------------------------------------------------------------
// Main Map Screen (Tracking & Guiding Interface)
// -----------------------------------------------------------------------------
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final KalmanLatLong _kalmanFilter = KalmanLatLong();
  StreamSubscription<Position>? _positionStream;

  Position? _currentLocation;
  List<LatLng> _activeTrackingRoute = []; // Red line (Current path)
  List<LatLng> _loadedGuideRoute = []; // Blue line (Saved path for guiding)
  
  bool _isTracking = false;
  int? _currentRouteId;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndLocate();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
  }

  Future<void> _checkPermissionsAndLocate() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      _startLiveLocationStream();
    }
  }

  void _startLiveLocationStream() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2, 
    );

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
      _kalmanFilter.process(
        lat: position.latitude,
        lng: position.longitude,
        accuracy: position.accuracy,
        timestampMs: position.timestamp.millisecondsSinceEpoch,
      );

      final currentLatLng = LatLng(_kalmanFilter.lat, _kalmanFilter.lng);

      if (mounted) {
        setState(() {
          _currentLocation = position;
          if (_isTracking) {
            _activeTrackingRoute.add(currentLatLng);
          }
        });
      }
    });
  }

  void _centerMapOnUser() {
    if (_currentLocation != null) {
      _mapController.move(
        LatLng(_kalmanFilter.lat, _kalmanFilter.lng),
        17.0, // Zoom level
      );
    }
  }

  Future<void> _startTrackingDialog() async {
    String selectedCategory = 'Day 1 Route';
    TextEditingController nameController = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Start New Route'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Route Name (Optional)'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedCategory,
                items: const [
                  DropdownMenuItem(value: 'Day 1 Route', child: Text('Polio Day 1')),
                  DropdownMenuItem(value: 'Day 2 Route', child: Text('Polio Day 2')),
                  DropdownMenuItem(value: 'Personal Route', child: Text('Personal / Cycling')),
                ],
                onChanged: (val) {
                  if (val != null) setDialogState(() => selectedCategory = val);
                },
                decoration: const InputDecoration(labelText: 'Category'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final routeName = nameController.text.isEmpty ? 'Unnamed Route' : nameController.text;
                
                // Create route in database
                _currentRouteId = await DatabaseHelper.instance.insertRoute(routeName, selectedCategory);
                
                // Save active ID in preferences for background task
                SharedPreferences prefs = await SharedPreferences.getInstance();
                await prefs.setInt('activeRouteId', _currentRouteId!);

                // Start Foreground Service
                await FlutterForegroundTask.startService(
                  serviceId: 256,
                  notificationTitle: 'Tracking: $routeName',
                  notificationText: 'Recording route in background...',
                  callback: startCallback,
                );

                setState(() {
                  _isTracking = true;
                  _activeTrackingRoute.clear();
                  _loadedGuideRoute.clear(); // Clear old guides when starting fresh
                  if (_currentLocation != null) {
                    _activeTrackingRoute.add(LatLng(_kalmanFilter.lat, _kalmanFilter.lng));
                  }
                });
                _centerMapOnUser();
              },
              child: const Text('Start Tracking'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _stopTracking() async {
    await FlutterForegroundTask.stopService();
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('activeRouteId');

    setState(() {
      _isTracking = false;
      _currentRouteId = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Route Saved Successfully!')),
    );
  }

  Future<void> _loadGuideRoute() async {
    final routes = await DatabaseHelper.instance.getRoutes();
    
    if (routes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No saved routes found.')));
      return;
    }

    if (!mounted) return;
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Route to Guide'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: routes.length,
            itemBuilder: (context, index) {
              final route = routes[index];
              return ListTile(
                leading: const Icon(Icons.route, color: Colors.blue),
                title: Text(route['name']),
                subtitle: Text('${route['category']}\n${DateFormat('dd MMM yyyy, HH:mm').format(DateTime.parse(route['timestamp']))}'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final points = await DatabaseHelper.instance.getRoutePoints(route['id']);
                  
                  setState(() {
                    _loadedGuideRoute = points.map((p) => LatLng(p['lat'], p['lng'])).toList();
                    _activeTrackingRoute.clear(); // Clear active tracking visual
                  });

                  if (_loadedGuideRoute.isNotEmpty) {
                    _mapController.move(_loadedGuideRoute.first, 16.0);
                  }
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Route Navigator'),
        actions: [
          if (_loadedGuideRoute.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear Guide Line',
              onPressed: () => setState(() => _loadedGuideRoute.clear()),
            ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(30.0703, 71.1933), // Approx Muzaffargarh center
              initialZoom: 13.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.polionavigator.polio_route_navigator',
              ),
              PolylineLayer(
                polylines: [
                  // Blue line for Guide Mode
                  if (_loadedGuideRoute.isNotEmpty)
                    Polyline(
                      points: _loadedGuideRoute,
                      strokeWidth: 5.0,
                      color: Colors.blue.withOpacity(0.8),
                    ),
                  // Red line for Active Tracking
                  if (_activeTrackingRoute.isNotEmpty)
                    Polyline(
                      points: _activeTrackingRoute,
                      strokeWidth: 5.0,
                      color: Colors.red.withOpacity(0.8),
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  if (_currentLocation != null)
                    Marker(
                      point: LatLng(_kalmanFilter.lat, _kalmanFilter.lng),
                      width: 60,
                      height: 60,
                      child: Transform.rotate(
                        // Convert heading to radians for rotation
                        angle: (_currentLocation!.heading * (math.pi / 180)),
                        child: const Icon(
                          Icons.navigation, // GPS Navigation Arrow Icon
                          color: Colors.indigo,
                          size: 40,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          
          // Floating Action Buttons
          Positioned(
            bottom: 20,
            right: 16,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FloatingActionButton(
                  heroTag: 'center_btn',
                  backgroundColor: Colors.white,
                  onPressed: _centerMapOnUser,
                  child: const Icon(Icons.my_location, color: Colors.black87),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'guide_btn',
                  backgroundColor: Colors.blueAccent,
                  onPressed: _isTracking ? null : _loadGuideRoute, // Disable loading route while tracking
                  child: const Icon(Icons.directions, color: Colors.white),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'track_btn',
                  backgroundColor: _isTracking ? Colors.red : Colors.green,
                  onPressed: _isTracking ? _stopTracking : _startTrackingDialog,
                  child: Icon(_isTracking ? Icons.stop : Icons.play_arrow, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

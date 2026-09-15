// lib/main.dart
// ==============================================================================
// 100% OFFLINE POLIO ROUTE NAVIGATOR (VISUAL MAP EDITION)
// Developed by: Asif Raza
// Features:
// 1. Visual Map with flutter_map & latlong2
// 2. Tracking Mode & Guide Mode
// 3. Dual Language Support (Urdu RTL & English)
// 4. Export & Share Routes via WhatsApp (JSON format)
// 5. Import Shared Routes
// 6. Live Compass Directions (N, S, E, W)
// 7. "Take Me Back" feature for return journeys
// ==============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// -----------------------------------------------------------------------------
// Global Language State
// -----------------------------------------------------------------------------
final ValueNotifier<Locale> appLocale = ValueNotifier(const Locale('ur')); // Default Urdu RTL

// -----------------------------------------------------------------------------
// Translations Dictionary
// -----------------------------------------------------------------------------
const Map<String, Map<String, String>> translations = {
  'en': {
    'title': 'Route Navigator',
    'developed_by': 'Developed by Asif Raza © All Rights Reserved',
    'start_new_route': 'Start New Route',
    'route_name': 'Route Name (Optional)',
    'category': 'Category',
    'start_tracking': 'Start Tracking',
    'stop_tracking': 'Stop Tracking',
    'select_route': 'Select Route to Guide',
    'import_success': 'Route imported successfully!',
    'route_saved': 'Route Saved Successfully!',
    'no_routes': 'No saved routes found.',
    'cancel': 'Cancel',
    'close': 'Close',
    'day1': 'Polio Day 1',
    'day2': 'Polio Day 2',
    'personal': 'Personal / Cycling',
    'clear_guide': 'Clear Guide Line',
    'import_btn': 'Import Shared Route',
    'take_me_back_msg': 'Return route loaded on the map!',
  },
  'ur': {
    'title': 'روٹ نیویگیٹر',
    'developed_by': 'آصف رضا کی تیار کردہ © جملہ حقوق محفوظ ہیں',
    'start_new_route': 'نیا راستہ شروع کریں',
    'route_name': 'راستے کا نام (اختیاری)',
    'category': 'زمرہ',
    'start_tracking': 'ٹریکنگ شروع کریں',
    'stop_tracking': 'ٹریکنگ روکیں',
    'select_route': 'رہنمائی کے لیے راستہ منتخب کریں',
    'import_success': 'راستہ کامیابی سے امپورٹ ہو گیا!',
    'route_saved': 'راستہ کامیابی سے محفوظ ہو گیا!',
    'no_routes': 'کوئی محفوظ شدہ راستہ نہیں ملا۔',
    'cancel': 'منسوخ کریں',
    'close': 'بند کریں',
    'day1': 'پولیو ڈے 1',
    'day2': 'پولیو ڈے 2',
    'personal': 'ذاتی راستہ / سائیکلنگ',
    'clear_guide': 'رہنمائی کی لکیر مٹائیں',
    'import_btn': 'راستہ امپورٹ کریں',
    'take_me_back_msg': 'واپسی کا راستہ نقشے پر لگا دیا گیا ہے!',
  }
};

String tr(BuildContext context, String key) {
  final lang = Localizations.localeOf(context).languageCode;
  return translations[lang]?[key] ?? key;
}

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
        notificationTitle: 'Tracking Route',
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
// SQLite Database Helper
// -----------------------------------------------------------------------------
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('polio_navigator_v3.db');
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
      allowWakeLock: false,
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
    return ValueListenableBuilder<Locale>(
      valueListenable: appLocale,
      builder: (context, locale, child) {
        return MaterialApp(
          title: 'Route Navigator',
          debugShowCheckedModeBanner: false,
          locale: locale,
          supportedLocales: const [
            Locale('en', ''),
            Locale('ur', ''),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0284C7)),
          ),
          home: const MapScreen(),
        );
      }
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
  List<LatLng> _activeTrackingRoute = []; 
  List<LatLng> _loadedGuideRoute = []; 
  
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
        17.0,
      );
    }
  }

  // --- Direction / Compass Helper Method ---
  String _getDirectionText(double? heading) {
    if (heading == null || heading < 0) return appLocale.value.languageCode == 'ur' ? 'سمت تلاش کر رہا ہے...' : 'Finding Direction...';
    if (heading >= 337.5 || heading < 22.5) return appLocale.value.languageCode == 'ur' ? 'شمال (North)' : 'North';
    if (heading >= 22.5 && heading < 67.5) return appLocale.value.languageCode == 'ur' ? 'شمال مشرق (NE)' : 'North East';
    if (heading >= 67.5 && heading < 112.5) return appLocale.value.languageCode == 'ur' ? 'مشرق (East)' : 'East';
    if (heading >= 112.5 && heading < 157.5) return appLocale.value.languageCode == 'ur' ? 'جنوب مشرق (SE)' : 'South East';
    if (heading >= 157.5 && heading < 202.5) return appLocale.value.languageCode == 'ur' ? 'جنوب (South)' : 'South';
    if (heading >= 202.5 && heading < 247.5) return appLocale.value.languageCode == 'ur' ? 'جنوب مغرب (SW)' : 'South West';
    if (heading >= 247.5 && heading < 292.5) return appLocale.value.languageCode == 'ur' ? 'مغرب (West)' : 'West';
    if (heading >= 292.5 && heading < 337.5) return appLocale.value.languageCode == 'ur' ? 'شمال مغرب (NW)' : 'North West';
    return '';
  }

  Future<void> _startTrackingDialog() async {
    String selectedCategory = 'day1';
    TextEditingController nameController = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(tr(context, 'start_new_route')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(labelText: tr(context, 'route_name')),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedCategory,
                items: [
                  DropdownMenuItem(value: 'day1', child: Text(tr(context, 'day1'))),
                  DropdownMenuItem(value: 'day2', child: Text(tr(context, 'day2'))),
                  DropdownMenuItem(value: 'personal', child: Text(tr(context, 'personal'))),
                ],
                onChanged: (val) {
                  if (val != null) setDialogState(() => selectedCategory = val);
                },
                decoration: InputDecoration(labelText: tr(context, 'category')),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(context, 'cancel'))),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final routeName = nameController.text.isEmpty ? 'Unnamed Route' : nameController.text;
                
                _currentRouteId = await DatabaseHelper.instance.insertRoute(routeName, selectedCategory);
                
                SharedPreferences prefs = await SharedPreferences.getInstance();
                await prefs.setInt('activeRouteId', _currentRouteId!);

                await FlutterForegroundTask.startService(
                  serviceId: 256,
                  notificationTitle: 'Tracking: $routeName',
                  notificationText: 'Recording route...',
                  callback: startCallback,
                );

                setState(() {
                  _isTracking = true;
                  _activeTrackingRoute.clear();
                  _loadedGuideRoute.clear(); 
                  if (_currentLocation != null) {
                    _activeTrackingRoute.add(LatLng(_kalmanFilter.lat, _kalmanFilter.lng));
                  }
                });
                _centerMapOnUser();
              },
              child: Text(tr(context, 'start_tracking')),
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
      SnackBar(content: Text(tr(context, 'route_saved'))),
    );
  }

  // --- Take Me Back Feature ---
  Future<void> _takeMeBack() async {
    if (_activeTrackingRoute.isEmpty) return;
    
    setState(() {
      // Reverse the active route and set it as guide route
      _loadedGuideRoute = _activeTrackingRoute.reversed.toList();
      _activeTrackingRoute.clear();
    });
    
    await _stopTracking(); // Stops tracking automatically
    _centerMapOnUser();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'take_me_back_msg'))),
    );
  }

  Future<void> _shareRoute(Map<String, dynamic> route) async {
    try {
      final points = await DatabaseHelper.instance.getRoutePoints(route['id']);
      final routeData = {
        'name': route['name'],
        'category': route['category'],
        'points': points,
      };
      
      final jsonStr = jsonEncode(routeData);
      final directory = await getTemporaryDirectory();
      String safeName = route['name'].toString().replaceAll(' ', '_');
      final file = File('${directory.path}/$safeName.json');
      await file.writeAsString(jsonStr);
      
      await Share.shareXFiles([XFile(file.path)], text: 'Shared Route: ${route['name']}');
    } catch (e) {
      debugPrint("Error sharing: $e");
    }
  }

  Future<void> _importRoute() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );
      
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final jsonStr = await file.readAsString();
        final data = jsonDecode(jsonStr);
        
        int newRouteId = await DatabaseHelper.instance.insertRoute(
          data['name'] + ' (Imported)', 
          data['category']
        );
        
        for (var pt in data['points']) {
          await DatabaseHelper.instance.insertRoutePoint(
            routeId: newRouteId, 
            lat: pt['lat'], 
            lng: pt['lng'], 
            timestamp: pt['timestamp']
          );
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'import_success'))),
        );
      }
    } catch (e) {
      debugPrint("Error importing: $e");
    }
  }

  Future<void> _loadGuideRoute() async {
    final routes = await DatabaseHelper.instance.getRoutes();
    
    if (routes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'no_routes'))));
      return;
    }

    if (!mounted) return;
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(context, 'select_route')),
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
                subtitle: Text('${tr(context, route['category'])}\n${DateFormat('dd MMM, HH:mm').format(DateTime.parse(route['timestamp']))}'),
                trailing: IconButton(
                  icon: const Icon(Icons.share, color: Colors.green),
                  onPressed: () => _shareRoute(route),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final points = await DatabaseHelper.instance.getRoutePoints(route['id']);
                  
                  setState(() {
                    _loadedGuideRoute = points.map((p) => LatLng(p['lat'], p['lng'])).toList();
                    _activeTrackingRoute.clear(); 
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(context, 'close'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'title'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            Text(
              tr(context, 'developed_by'),
              style: const TextStyle(fontSize: 10, color: Colors.black54, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: tr(context, 'import_btn'),
            onPressed: _importRoute,
          ),
          IconButton(
            icon: const Icon(Icons.language),
            tooltip: 'Language / زبان',
            onPressed: () {
              appLocale.value = appLocale.value.languageCode == 'en' 
                ? const Locale('ur') 
                : const Locale('en');
            },
          ),
          if (_loadedGuideRoute.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: tr(context, 'clear_guide'),
              onPressed: () => setState(() => _loadedGuideRoute.clear()),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12.0, left: 8.0),
            child: ClipOval(
              child: Image.asset(
                'assets/developer.jpg',
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const CircleAvatar(
                  backgroundColor: Colors.grey,
                  child: Icon(Icons.person, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(30.0703, 71.1933), 
              initialZoom: 13.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.polionavigator.polio_route_navigator',
              ),
              PolylineLayer(
                polylines: [
                  if (_loadedGuideRoute.isNotEmpty)
                    Polyline(
                      points: _loadedGuideRoute,
                      strokeWidth: 5.0,
                      color: Colors.blue.withOpacity(0.8),
                    ),
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
                        angle: (_currentLocation!.heading * (math.pi / 180)),
                        child: const Icon(
                          Icons.navigation,
                          color: Colors.indigo,
                          size: 40,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          
          // --- Live Compass Directions ---
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 4),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.explore, color: Colors.indigo, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      _getDirectionText(_currentLocation?.heading),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Floating Action Buttons
          Positioned(
            bottom: 20,
            right: appLocale.value.languageCode == 'en' ? 16 : null,
            left: appLocale.value.languageCode == 'ur' ? 16 : null,
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
                
                // --- Take Me Back Button (Only visible during active tracking) ---
                if (_isTracking)
                  FloatingActionButton(
                    heroTag: 'take_back_btn',
                    backgroundColor: Colors.orange,
                    tooltip: 'Take Me Back',
                    onPressed: _takeMeBack,
                    child: const Icon(Icons.u_turn_left, color: Colors.white),
                  ),
                
                if (_isTracking) const SizedBox(height: 12),

                FloatingActionButton(
                  heroTag: 'guide_btn',
                  backgroundColor: Colors.blueAccent,
                  onPressed: _isTracking ? null : _loadGuideRoute, 
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

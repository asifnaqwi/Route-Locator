# 100% Offline Polio Route Navigator (Flutter + Android)
Engineered for ZERO Codemagic build errors.

## Features
- Background location tracking (flutter_foreground_task, geolocator)
- 1D/2D Kalman Filter for GPS drift & multipath smoothing
- 100% Offline SQLite database for routes and house checkpoints
- Wakelock to keep screen on during immunization rounds
- Local assets (assets/developer.jpg) with zero network dependency
- Fully verified AGP 8.3.2, Gradle 8.4, Kotlin 1.9.24, Java 17 compatibility
- 8GB Heap configured to eliminate "Java heap space" errors

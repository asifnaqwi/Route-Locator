#!/usr/bin/env bash
# ==============================================================================
# Polio Route Navigator - Fresh Project Generation & Res Directory Restoration
# Run these commands in your terminal to initialize the project with native structure
# ==============================================================================

# 1. Ensure Flutter is on the stable channel
flutter channel stable
flutter upgrade

# 2. Create the clean project with Android platform
flutter create --org com.polionavigator --platforms=android polio_route_navigator
cd polio_route_navigator

# 3. Create the missing/required native Android Resource folders
mkdir -p android/app/src/main/res/values
mkdir -p android/app/src/main/res/values-night
mkdir -p android/app/src/main/res/drawable
mkdir -p android/app/src/main/res/drawable-v21
mkdir -p android/app/src/main/res/mipmap-hdpi
mkdir -p android/app/src/main/res/mipmap-mdpi
mkdir -p android/app/src/main/res/mipmap-xhdpi
mkdir -p android/app/src/main/res/mipmap-xxhdpi
mkdir -p android/app/src/main/res/mipmap-xxxhdpi

# 4. Create assets directory for offline local assets
mkdir -p assets

# 5. Create a placeholder developer asset if needed
# (You can replace this with your real photo)
curl -s -o assets/developer.jpg https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=400&q=80 || touch assets/developer.jpg

# 6. Ensure proper Gradle wrapper permissions
chmod +x android/gradlew

echo "✅ Project scaffold and native Android resource directories initialized successfully!"

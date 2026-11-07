# Friendra

Friendra is a Flutter mobile app for trusted friends to connect, share
locations with consent, and communicate safely.

## Current features

- Firebase email/password sign-in and account creation
- Persistent Firebase login sessions
- Friend requests with accept, decline, refresh, and remove actions
- Reciprocal connected-friend records
- Opt-in live location sharing with an immediate stop control
- Interactive OpenStreetMap view with friend location markers
- Map pan, pinch zoom, refresh, and recenter controls
- Material 3 navigation for Map, Updates, Chat, Profile, and Friends

Location sharing is off by default. A user must explicitly enable it, grant
device permission, and can stop sharing at any time. Location data is removed
from the user's active location record when sharing is stopped.

## Technology

- Flutter
- Firebase Authentication
- Firebase Realtime Database
- `flutter_map` with OpenStreetMap tiles
- `geolocator`

Planned features include Firebase Storage photo/video updates, Firebase Cloud
Messaging notifications, and Realtime Database chat.

## Firebase setup

This project is configured for the `friendra-9e18b` Firebase project using
FlutterFire-generated platform configuration. Enable Email/Password in:

**Firebase Console > Authentication > Sign-in providers**

Realtime Database rules are stored in [`database.rules.json`](database.rules.json)
and can be deployed with:

```bash
firebase deploy --only database
```

The app uses these Realtime Database paths:

- `users/{uid}/friends/{friendUid}` for connected friends
- `users/{uid}/location` for the user's active shared location
- `friend_requests/{requestId}` for requests, queried by recipient email
- `connections/{userA}_{userB}` for reciprocal connection access

Do not add service-account keys, private certificates, or other secrets to the
repository. Firebase client configuration is not a service-account credential,
but production deployments should still use the correct Firebase project and
security rules.

## Getting started

Install Flutter and Android tooling, then run:

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

For Android, the debug APK is generated at:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

Install it on a connected emulator or device with:

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The primary development emulator is `Medium_Phone_API_37.0`. Emulator GPU
context errors are normally Android Emulator rendering issues rather than
Friendra application errors; software rendering or a different AVD can help.
import 'package:flutter/material.dart';
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AuthService authService;
  FriendsService friendsService;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    authService = FirebaseAuthService(FirebaseAuth.instance);
    friendsService = RealtimeDatabaseFriendsService(
      FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://friendra-9e18b-default-rtdb.asia-southeast1.firebasedatabase.app',
      ),
      FirebaseAuth.instance,
    );
  } on FirebaseException catch (error) {
    authService = UnavailableAuthService(
      'Firebase is not configured for this app yet (${error.code}).',
    );
    friendsService = LocalFriendsService();
  }
  runApp(
    FriendraApp(
      authService: authService,
      friendsService: friendsService,
    ),
  );
}

class FriendraApp extends StatefulWidget {
  const FriendraApp({
    required this.authService,
    required this.friendsService,
    super.key,
  });

  final AuthService authService;
  final FriendsService friendsService;

  @override
  State<FriendraApp> createState() => _FriendraAppState();
}

class _FriendraAppState extends State<FriendraApp> {
  late bool _isAuthenticated = widget.authService.isAuthenticated;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Friendra',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF315CFF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FC),
        useMaterial3: true,
      ),
      home: _isAuthenticated
          ? FriendraHome(
              friendsService: widget.friendsService,
              onSignOut: () async {
                await widget.authService.signOut();
                if (mounted) setState(() => _isAuthenticated = false);
              },
            )
          : AuthScreen(
              authService: widget.authService,
              onAuthenticated: () => setState(() => _isAuthenticated = true),
            ),
    );
  }
}

abstract interface class AuthService {
  bool get isAuthenticated;

  Future<void> signIn(String email, String password);

  Future<void> createAccount(String name, String email, String password);

  Future<void> signOut();
}

abstract interface class FriendsService {
  Future<List<Friend>> loadFriends();

  Future<List<Friend>> loadRequests();

  Future<List<FriendLocation>> loadFriendLocations();

  Future<void> sendRequest(Friend friend);

  Future<void> acceptRequest(Friend friend);

  Future<void> declineRequest(Friend friend);

  Future<void> removeFriend(Friend friend);
}

class RealtimeDatabaseFriendsService implements FriendsService {
  RealtimeDatabaseFriendsService(this._database, this._auth);

  final FirebaseDatabase _database;
  final FirebaseAuth _auth;

  User get _user {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Sign in before managing friends.');
    return user;
  }

  String _key(String value) => value.replaceAll(RegExp(r'[.#$[\]]'), '_');

  DatabaseReference get _friendsReference =>
      _database.ref('users/${_user.uid}/friends');

  @override
  Future<List<Friend>> loadFriends() async {
    final snapshot = await _friendsReference.get();
    return snapshot.children
        .map(Friend.fromSnapshot)
        .where((friend) => friend.status == 'Connected')
        .toList();
  }

  @override
  Future<List<Friend>> loadRequests() async {
    final snapshot = await _database
        .ref('friend_requests')
        .orderByChild('recipientEmail')
        .equalTo(_user.email)
        .get();
    return snapshot.children
        .where((request) => request.child('status').value == 'pending')
        .map(Friend.fromRequestSnapshot)
        .toList();
  }

  @override
  Future<List<FriendLocation>> loadFriendLocations() async {
    final friends = await loadFriends();
    final locations = <FriendLocation>[];
    for (final friend in friends) {
      final uid = friend.uid;
      if (uid == null) continue;
      final snapshot = await _database.ref('users/$uid/location').get();
      locations.add(FriendLocation.fromSnapshot(friend, snapshot));
    }
    return locations;
  }

  @override
  Future<void> sendRequest(Friend friend) async {
    await _database.ref('friend_requests').push().set({
      'senderUid': _user.uid,
      'senderName': _user.displayName ?? 'Friendra user',
      'senderEmail': _user.email,
      'recipientEmail': friend.email,
      'recipientName': friend.name,
      'status': 'pending',
      'createdAt': ServerValue.timestamp,
    });
  }

  @override
  Future<void> acceptRequest(Friend friend) async {
    final senderUid = friend.uid;
    if (senderUid == null) {
      throw StateError('This request is missing the sender account. Refresh and try again.');
    }
    await _database.ref('connections/${senderUid}_${_user.uid}').set({
      'userA': senderUid,
      'userB': _user.uid,
    });
    await _friendsReference
        .child(senderUid)
        .set(friend.copyWith(status: 'Connected').toMap());
    await _database
        .ref('users/$senderUid/friends/${_user.uid}')
        .set(
          Friend(
            uid: _user.uid,
            name: _user.displayName ?? 'Friendra user',
            email: _user.email ?? '',
            status: 'Connected',
            color: friend.color,
          ).toMap(),
        );
    await _updateRequestStatus(friend, 'accepted');
  }

  @override
  Future<void> declineRequest(Friend friend) =>
      _updateRequestStatus(friend, 'declined');

  Future<void> _updateRequestStatus(Friend friend, String status) async {
    final requestId = friend.requestId;
    if (requestId == null) {
      throw StateError('This request is missing its ID. Refresh and try again.');
    }
    await _database.ref('friend_requests/$requestId').update({'status': status});
  }

  @override
  Future<void> removeFriend(Friend friend) =>
      _friendsReference.child(friend.uid ?? _key(friend.email)).remove();
}

class LocalFriendsService implements FriendsService {
  final List<Friend> _friends = [];
  final List<Friend> _requests = [];

  @override
  Future<List<Friend>> loadFriends() async => List.of(_friends);
  @override
  Future<List<Friend>> loadRequests() async => List.of(_requests);
  @override
  Future<List<FriendLocation>> loadFriendLocations() async => [];
  @override
  Future<void> sendRequest(Friend friend) async => _requests.add(friend);
  @override
  Future<void> acceptRequest(Friend friend) async {
    _requests.remove(friend);
    _friends.add(friend.copyWith(status: 'Connected'));
  }
  @override
  Future<void> declineRequest(Friend friend) async => _requests.remove(friend);
  @override
  Future<void> removeFriend(Friend friend) async => _friends.remove(friend);
}

class FirebaseAuthService implements AuthService {
  FirebaseAuthService(this._auth);

  final FirebaseAuth _auth;

  @override
  bool get isAuthenticated => _auth.currentUser != null;

  FirebaseDatabase get _database => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://friendra-9e18b-default-rtdb.asia-southeast1.firebasedatabase.app',
      );

  String _emailKey(String email) =>
      email.trim().toLowerCase().replaceAll(RegExp(r'[.#$[\]]'), '_');

  Future<void> _syncDirectory(User user) async {
    final email = user.email;
    if (email == null) return;
    await _database.ref('directory/${_emailKey(email)}').set({
      'uid': user.uid,
      'email': email.trim().toLowerCase(),
      'name': user.displayName ?? 'Friendra user',
    });
  }

  void _syncDirectoryInBackground(User user) {
    unawaited(
      _syncDirectory(user).catchError((error, stackTrace) {
        debugPrint('Friendra directory sync failed: $error');
      }),
    );
  }

  @override
  Future<void> signIn(String email, String password) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    _syncDirectoryInBackground(credential.user!);
  }

  @override
  Future<void> createAccount(
    String name,
    String email,
    String password,
  ) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await credential.user?.updateDisplayName(name);
    if (credential.user != null) {
      _syncDirectoryInBackground(credential.user!);
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();
}

class UnavailableAuthService implements AuthService {
  UnavailableAuthService(this.message);

  final String message;

  @override
  bool get isAuthenticated => false;

  @override
  Future<void> signIn(String email, String password) =>
      Future.error(StateError(message));

  @override
  Future<void> createAccount(String name, String email, String password) =>
      Future.error(StateError(message));

  @override
  Future<void> signOut() => Future.value();
}

class DemoAuthService implements AuthService {
  @override
  bool get isAuthenticated => false;

  @override
  Future<void> signIn(String email, String password) => Future.value();

  @override
  Future<void> createAccount(String name, String email, String password) =>
      Future.value();

  @override
  Future<void> signOut() => Future.value();
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    required this.authService,
    required this.onAuthenticated,
    super.key,
  });

  final AuthService authService;
  final VoidCallback onAuthenticated;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _hidePassword = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      if (_isSignUp) {
        await widget.authService.createAccount(
          _nameController.text.trim(),
          _emailController.text.trim(),
          _passwordController.text,
        );
      } else {
        await widget.authService.signIn(
          _emailController.text.trim(),
          _passwordController.text,
        );
      }
      if (mounted) widget.onAuthenticated();
    } on FirebaseAuthException catch (error) {
      if (mounted) setState(() => _errorMessage = _authError(error.code));
    } on StateError catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String _authError(String code) {
    return switch (code) {
      'invalid-credential' || 'user-not-found' || 'wrong-password' =>
        'The email or password is incorrect.',
      'email-already-in-use' => 'An account already exists for this email.',
      'operation-not-allowed' =>
        'Email/password sign-in is disabled in Firebase Console.',
      'invalid-email' => 'This email address is not valid.',
      'weak-password' => 'Choose a stronger password.',
      'network-request-failed' => 'Check your internet connection and try again.',
      'too-many-requests' => 'Too many attempts. Please wait and try again.',
      'internal-error' => 'Firebase returned an internal error. Try again.',
      _ => 'Authentication failed. Please try again.',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.hub_rounded, size: 64, color: Color(0xFF315CFF)),
                  const SizedBox(height: 16),
                  Text(
                    'Welcome to Friendra',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Stay close to the people you trust.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Sign in')),
                      ButtonSegment(value: true, label: Text('Create account')),
                    ],
                    selected: {_isSignUp},
                    onSelectionChanged: (selection) {
                      setState(() => _isSignUp = selection.first);
                    },
                  ),
                  const SizedBox(height: 24),
                  if (_isSignUp)
                    TextFormField(
                      controller: _nameController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Your name',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value == null || value.trim().isEmpty
                          ? 'Enter your name'
                          : null,
                    ),
                  if (_isSignUp) const SizedBox(height: 16),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Email address',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || !value.contains('@')
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _hidePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _hidePassword = !_hidePassword),
                        icon: Icon(
                          _hidePassword ? Icons.visibility : Icons.visibility_off,
                        ),
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || value.length < 6
                        ? 'Use at least 6 characters'
                        : null,
                  ),
                  const SizedBox(height: 24),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  FilledButton(
                    onPressed: _isSubmitting ? null : _submit,
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isSignUp ? 'Create account' : 'Sign in'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Your location stays private and sharing is always opt-in.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FriendraHome extends StatefulWidget {
  const FriendraHome({
    required this.friendsService,
    required this.onSignOut,
    super.key,
  });

  final FriendsService friendsService;
  final VoidCallback onSignOut;

  @override
  State<FriendraHome> createState() => _FriendraHomeState();
}

class _FriendraHomeState extends State<FriendraHome> {
  int _selectedIndex = 0;
  bool _isSharingLocation = false;
  StreamSubscription<Position>? _locationSubscription;

  @override
  void dispose() {
    _locationSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _MapPage(friendsService: widget.friendsService),
      const _UpdatesPage(),
      const _ChatsPage(),
      _ProfilePage(
        friendsService: widget.friendsService,
        onSignOut: widget.onSignOut,
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: _selectedIndex, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.dynamic_feed_outlined),
            selectedIcon: Icon(Icons.dynamic_feed),
            label: 'Updates',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton.extended(
              onPressed: () => _showLocationConsent(context),
              icon: Icon(
                _isSharingLocation ? Icons.location_on : Icons.location_off,
              ),
              label: Text(_isSharingLocation ? 'Sharing on' : 'Share location'),
            )
          : null,
    );
  }

  Future<void> _showLocationConsent(BuildContext context) async {
    final shouldShare = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isSharingLocation
                  ? 'Stop sharing your location?'
                  : 'Share your live location?',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              _isSharingLocation
                  ? 'Your friends will no longer see your live position.'
                  : 'Only friends you choose will see your live position. '
                      'You can stop sharing at any time.',
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_isSharingLocation ? 'Stop sharing' : 'Continue'),
            ),
          ],
        ),
      ),
    );

    if (shouldShare != true || !context.mounted) {
      return;
    }

    if (shouldShare == true) {
      await _startLocationSharing();
    } else {
      await _stopLocationSharing();
    }
  }

  Future<void> _startLocationSharing() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showLocationError('Turn on device location services and try again.');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _showLocationError('Location permission is required to share your location.');
      return;
    }

    final position = await Geolocator.getCurrentPosition();
    await _saveLocation(position);
    await _locationSubscription?.cancel();
    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 25,
      ),
    ).listen((position) {
      _saveLocation(position);
    });

    if (!mounted) return;
    setState(() => _isSharingLocation = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Location sharing is now active.')),
    );
  }

  Future<void> _stopLocationSharing() async {
    await _locationSubscription?.cancel();
    _locationSubscription = null;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://friendra-9e18b-default-rtdb.asia-southeast1.firebasedatabase.app',
      ).ref('users/${user.uid}/location').remove();
    }
    if (!mounted) return;
    setState(() => _isSharingLocation = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Location sharing stopped.')),
    );
  }

  Future<void> _saveLocation(Position position) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL:
          'https://friendra-9e18b-default-rtdb.asia-southeast1.firebasedatabase.app',
    ).ref('users/${user.uid}/location').set({
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'updatedAt': ServerValue.timestamp,
      'sharing': true,
    });
  }

  void _showLocationError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _MapPage extends StatefulWidget {
  const _MapPage({required this.friendsService});

  final FriendsService friendsService;

  @override
  State<_MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<_MapPage> {
  List<FriendLocation> _locations = [];
  Timer? _refreshTimer;
  final MapController _mapController = MapController();
  bool _isLoading = true;
  String? _errorMessage;
  bool _hasCenteredOnFriend = false;

  @override
  void initState() {
    super.initState();
    _loadLocations();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadLocations(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadLocations() async {
    try {
      final locations = await widget.friendsService.loadFriendLocations();
      if (!mounted) return;
      setState(() {
        _locations = locations;
        _isLoading = false;
        _errorMessage = null;
      });
      _centerOnFirstFriend(locations);
    } on FirebaseException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to load locations (${error.code}).';
      });
    }

  }

  void _centerOnFirstFriend(List<FriendLocation> locations) {
    if (_hasCenteredOnFriend) return;
    final location = locations.where(
      (item) =>
          item.isSharing &&
          item.latitude != null &&
          item.longitude != null,
    );
    if (location.isEmpty) return;
    final first = location.first;
    _hasCenteredOnFriend = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(
        LatLng(first.latitude!, first.longitude!),
        14,
      );
    });
  }

  void _centerOnVisibleFriend() {
    final location = _locations.where(
      (item) =>
          item.isSharing &&
          item.latitude != null &&
          item.longitude != null,
    );
    if (location.isEmpty) {
      _loadLocations();
      return;
    }
    final first = location.first;
    _mapController.move(
      LatLng(first.latitude!, first.longitude!),
      14,
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleLocations = _locations
        .where(
          (location) =>
              location.isSharing &&
              location.latitude != null &&
              location.longitude != null,
        )
        .toList();
    final mapCenter = visibleLocations.isNotEmpty
        ? LatLng(
            visibleLocations.first.latitude!,
            visibleLocations.first.longitude!,
          )
        : const LatLng(20, 0);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        const _PageHeader(
          title: 'Good morning, Samson',
          subtitle: 'Your trusted circle',
        ),
        const SizedBox(height: 20),
        Container(
          height: 330,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(28)),
          child: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: mapCenter,
                  initialZoom: visibleLocations.isNotEmpty ? 14 : 2,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.friendra',
                  ),
                  MarkerLayer(
                    markers: visibleLocations
                        .map(
                          (location) => Marker(
                            point: LatLng(
                              location.latitude!,
                              location.longitude!,
                            ),
                            width: 120,
                            height: 70,
                            child: _MapMarker(
                              name: location.friend.name,
                              color: location.friend.color,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
              Positioned(
                top: 16,
                right: 16,
                child: IconButton.filled(
                  onPressed: _centerOnVisibleFriend,
                  icon: const Icon(Icons.my_location),
                  tooltip: 'Center on friend',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text('Friends nearby', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (_isLoading) const LinearProgressIndicator(),
        if (_errorMessage != null)
          Text(
            _errorMessage!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (!_isLoading && _locations.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.people_outline),
              title: Text('No connected friends yet'),
              subtitle: Text('Connect with a friend to see their location.'),
            ),
          ),
        ..._locations.map(
          (location) => Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: location.friend.color,
                child: Text(location.friend.name.substring(0, 1)),
              ),
              title: Text(location.friend.name),
              subtitle: Text(
                location.isSharing &&
                        location.latitude != null &&
                        location.longitude != null
                    ? '${location.latitude!.toStringAsFixed(5)}, '
                        '${location.longitude!.toStringAsFixed(5)}'
                    : 'Location sharing paused',
              ),
              trailing: Icon(
                location.isSharing
                    ? Icons.location_on
                    : Icons.location_off_outlined,
                color: location.isSharing
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UpdatesPage extends StatelessWidget {
  const _UpdatesPage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: const [
        _PageHeader(title: 'Updates', subtitle: 'What your circle is up to'),
        SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: Icon(Icons.dynamic_feed_outlined),
            title: Text('No updates yet'),
            subtitle: Text('Updates from your connected friends will appear here.'),
          ),
        ),
      ],
    );
  }
}

class _ChatsPage extends StatelessWidget {
  const _ChatsPage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        const _PageHeader(title: 'Chats', subtitle: 'Stay connected'),
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: Icon(Icons.chat_bubble_outline,
                color: Theme.of(context).colorScheme.primary),
            title: const Text('No conversations yet'),
            subtitle: const Text('Connect with a friend to start chatting.'),
          ),
        ),
      ],
    );
  }
}

class _ProfilePage extends StatelessWidget {
  const _ProfilePage({
    required this.friendsService,
    required this.onSignOut,
  });

  final FriendsService friendsService;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        const _PageHeader(title: 'Profile', subtitle: 'Your privacy, your control'),
        const SizedBox(height: 24),
        const CircleAvatar(
          radius: 42,
          backgroundColor: Color(0xFFDCE4FF),
          child: Icon(Icons.person, size: 44, color: Color(0xFF315CFF)),
        ),
        const SizedBox(height: 12),
        Text(
          _profileName(),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 28),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Trusted friends'),
                subtitle: const Text('Manage who can see your location'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _FriendsPage(
                        friendsService: friendsService,
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('Notifications'),
                subtitle: const Text('Alerts, check-ins, and messages'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: onSignOut,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _profileName() {
  if (Firebase.apps.isEmpty) return 'Friendra user';
  return FirebaseAuth.instance.currentUser?.displayName ??
      FirebaseAuth.instance.currentUser?.email ??
      'Friendra user';
}

class _FriendsPage extends StatefulWidget {
  const _FriendsPage({required this.friendsService});

  final FriendsService friendsService;

  @override
  State<_FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<_FriendsPage> {
  List<Friend> _friends = [];
  List<Friend> _requests = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  Future<void> _loadFriends() async {
    try {
      final friends = await widget.friendsService.loadFriends();
      final requests = await widget.friendsService.loadRequests();
      if (!mounted) return;
      setState(() {
        _friends = friends;
        _requests = requests;
        _isLoading = false;
      });
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Unable to load friends (${error.code}): ${error.message ?? 'Check Firebase rules and connection.'}';
          _isLoading = false;
        });
      }
    } on StateError catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = error.message;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _addFriend() async {
    final result = await showDialog<Friend>(
      context: context,
      builder: (context) => const _AddFriendDialog(),
    );
    if (result == null || !mounted) return;

    try {
      await widget.friendsService.sendRequest(result);
      if (!mounted) return;
    } on FirebaseException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Unable to send request (${error.code}).');
      return;
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Request sent to ${result.name}.')),
    );
  }

  Future<void> _acceptRequest(Friend friend) async {
    await widget.friendsService.acceptRequest(friend);
    if (!mounted) return;
    setState(() {
      _requests.remove(friend);
      _friends.add(friend.copyWith(status: 'Connected'));
    });
  }

  Future<void> _removeFriend(Friend friend) async {
    await widget.friendsService.removeFriend(friend);
    if (!mounted) return;
    setState(() => _friends.remove(friend));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${friend.name} removed from your circle.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trusted friends'),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _loadFriends,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh requests',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addFriend,
        icon: const Icon(Icons.person_add),
        label: const Text('Add friend'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadFriends,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          children: [
          if (_isLoading) const LinearProgressIndicator(),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Text(
            'Only trusted friends can receive your location and updates.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          if (_requests.isNotEmpty) ...[
            Text(
              'Connection requests',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ..._requests.map(
              (friend) => _RequestTile(
                friend: friend,
                onAccept: () => _acceptRequest(friend),
                onDecline: () async {
                  await widget.friendsService.declineRequest(friend);
                  if (mounted) setState(() => _requests.remove(friend));
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
          Text('Your circle', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_friends.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('Your trusted circle is empty. Add a friend to begin.'),
            )
          else
            ..._friends.map(
              (friend) => _FriendManagementTile(
                friend: friend,
                onRemove: () => _removeFriend(friend),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Friend {
  const Friend({
    this.uid,
    this.requestId,
    required this.name,
    required this.email,
    required this.status,
    required this.color,
  });

  final String? uid;
  final String? requestId;
  final String name;
  final String email;
  final String status;
  final Color color;

  factory Friend.fromSnapshot(DataSnapshot snapshot) {
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    return Friend(
      name: data['name'] as String? ?? 'Friend',
      email: data['email'] as String? ?? '',
      uid: data['uid'] as String?,
      status: data['status'] as String? ?? 'Connected',
      color: const Color(0xFF7E8CE0),
    );
  }

  factory Friend.fromRequestSnapshot(DataSnapshot snapshot) {
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    return Friend(
      name: data['senderName'] as String? ?? 'Friend',
      email: data['senderEmail'] as String? ?? '',
      uid: data['senderUid'] as String?,
      requestId: snapshot.key,
      status: 'Wants to connect',
      color: const Color(0xFF7E8CE0),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'status': status,
      if (uid != null) 'uid': uid,
    };
  }

  Friend copyWith({String? status}) {
    return Friend(
      name: name,
      email: email,
      uid: uid,
      requestId: requestId,
      status: status ?? this.status,
      color: color,
    );
  }
}

class FriendLocation {
  const FriendLocation({
    required this.friend,
    required this.latitude,
    required this.longitude,
    required this.isSharing,
    this.updatedAt,
  });

  final Friend friend;
  final double? latitude;
  final double? longitude;
  final bool isSharing;
  final int? updatedAt;

  factory FriendLocation.fromSnapshot(
    Friend friend,
    DataSnapshot snapshot,
  ) {
    final raw = snapshot.value;
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    return FriendLocation(
      friend: friend,
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      isSharing: data['sharing'] == true,
      updatedAt: data['updatedAt'] as int?,
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.friend,
    required this.onAccept,
    required this.onDecline,
  });

  final Friend friend;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: friend.color,
          child: Text(friend.name.substring(0, 1)),
        ),
        title: Text(friend.name),
        subtitle: Text(friend.email),
        trailing: Wrap(
          children: [
            IconButton(
              onPressed: onDecline,
              icon: const Icon(Icons.close),
              tooltip: 'Decline request',
            ),
            IconButton(
              onPressed: onAccept,
              icon: const Icon(Icons.check),
              tooltip: 'Accept request',
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendManagementTile extends StatelessWidget {
  const _FriendManagementTile({
    required this.friend,
    required this.onRemove,
  });

  final Friend friend;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: friend.color,
        child: Text(friend.name.substring(0, 1)),
      ),
      title: Text(friend.name),
      subtitle: Text('${friend.email} Â· ${friend.status}'),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'remove') onRemove();
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'remove', child: Text('Remove friend')),
        ],
      ),
    );
  }
}

class _AddFriendDialog extends StatefulWidget {
  const _AddFriendDialog();

  @override
  State<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<_AddFriendDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      Friend(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        status: 'Request pending',
        color: const Color(0xFF315CFF),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a trusted friend'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Friend name'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? 'Enter a name' : null,
            ),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email address'),
              validator: (value) => value == null || !value.contains('@')
                  ? 'Enter a valid email'
                  : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Send request')),
      ],
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _MapMarker extends StatelessWidget {
  const _MapMarker({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CircleAvatar(
          backgroundColor: color,
          child: Text(name.substring(0, 1)),
        ),
        const SizedBox(height: 4),
        DecoratedBox(
          decoration: const BoxDecoration(color: Colors.white),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(name),
          ),
        ),
      ],
    );
  }
}

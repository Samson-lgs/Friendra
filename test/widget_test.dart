import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:friendra/main.dart';

void main() {
  testWidgets('Friendra opens on authentication screen', (tester) async {
    await tester.pumpWidget(
      FriendraApp(
        authService: DemoAuthService(),
        friendsService: LocalFriendsService(),
      ),
    );

    expect(find.text('Welcome to Friendra'), findsOneWidget);
    expect(find.text('Sign in'), findsNWidgets(2));
    expect(find.text('Create account'), findsOneWidget);
  });

  testWidgets('Friendra opens the map after signing in', (tester) async {
    await tester.pumpWidget(
      FriendraApp(
        authService: DemoAuthService(),
        friendsService: LocalFriendsService(),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address'),
      'samson@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'password',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Good morning, Samson'), findsOneWidget);
    expect(find.text('Friends nearby'), findsOneWidget);
  });
}

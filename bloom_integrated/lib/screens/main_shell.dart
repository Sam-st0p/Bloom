// lib/screens/main_shell.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/connectivity_service.dart';
import '../widgets/common_widgets.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'events_screen.dart';
import 'badges_screen.dart';
import 'profile_screen.dart';
import 'notifications_screen.dart';
import 'notification_provider.dart';

class MainShell extends StatefulWidget {
  final VoidCallback onSignOut;

  /// Role resolved by AuthGate before navigating here.
  /// Passed straight to HomeScreen so it never needs to re-query
  /// the profile just to show the role pill — avoiding the race
  /// condition where HomeScreen reads 'student' before AuthGate
  /// finishes writing 'guest' for Google users.
  final String resolvedRole;

  const MainShell({
    super.key,
    required this.onSignOut,
    this.resolvedRole = '', // empty = HomeScreen fetches it normally
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  int _eventsInitialTab = 0;
  int _badgesInitialTab = 0;

  bool _online = true;
  StreamSubscription<bool>? _connSub;

  final _notifProvider = NotificationProvider();

  @override
  void initState() {
    super.initState();
    _notifProvider.init();
    _notifProvider.addListener(_onProviderChange);

    // Initial connectivity check
    ConnectivityService.instance.hasInternet().then((v) {
      if (mounted) setState(() => _online = v);
    });

    // Live updates (airplane mode on/off, wifi drops, etc.)
    _connSub = ConnectivityService.instance.onStatusChange.listen((v) {
      if (mounted) setState(() => _online = v);
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _notifProvider.removeListener(_onProviderChange);
    _notifProvider.dispose();
    super.dispose();
  }

  void _onProviderChange() {
    if (mounted) setState(() {});
  }

  void _navigateTo(int index) {
    setState(() {
      _currentIndex = index;
      if (index == 2) _eventsInitialTab = 0;
      if (index == 3) _badgesInitialTab = 0;
    });
  }

  void _openNotifications() {
    Navigator.push<NavResult>(
      context,
      MaterialPageRoute(
        builder: (_) => NotificationProviderWidget(
          provider: _notifProvider,
          child: const NotificationsScreen(),
        ),
      ),
    ).then((result) {
      if (result == null) return;
      switch (result) {
        case NavResult.library:
          setState(() => _currentIndex = 1);
          break;
        case NavResult.events:
          setState(() {
            _eventsInitialTab = 0;
            _currentIndex = 2;
          });
          break;
        case NavResult.calendar:
          setState(() {
            _eventsInitialTab = 1;
            _currentIndex = 2;
          });
          break;
        case NavResult.achievements:
          setState(() {
            _badgesInitialTab = 0;
            _currentIndex = 3;
          });
          break;
        case NavResult.certificates:
          setState(() {
            _badgesInitialTab = 1;
            _currentIndex = 3;
          });
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final unreadCount = _notifProvider.unreadCount;

    final screens = [
      HomeScreen(
        onSwitchTab: _navigateTo,
        onOpenNotifications: _openNotifications,
        unreadCount: unreadCount,
        resolvedRole: widget.resolvedRole, // passed in, no extra query
        onJoinLive: (seminar) {
          setState(() {
            _eventsInitialTab = 0;
            _currentIndex = 2;
          });
        },
        onOpenCalendar: () {
          // Forum tile — jump straight to the Calendar sub-tab of Events
          // until a real Forum tab exists.
          setState(() {
            _eventsInitialTab = 1;
            _currentIndex = 2;
          });
        },
      ),
      const LibraryScreen(),
      EventsScreen(initialTab: _eventsInitialTab),
      BadgesScreen(initialTab: _badgesInitialTab),
      ProfileScreen(onSignOut: widget.onSignOut),
    ];

    return NotificationProviderWidget(
      provider: _notifProvider,
      child: Scaffold(
        body: Column(
          children: [
            Expanded(child: screens[_currentIndex]),
            if (!_online) const OfflineBanner(),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: const Border(top: BorderSide(color: AppColors.border)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  _NavItem(icon: Icons.home_outlined, activeIcon: Icons.home_rounded, label: 'Home', index: 0, currentIndex: _currentIndex, onTap: _navigateTo),
                  _NavItem(icon: Icons.menu_book_outlined, activeIcon: Icons.menu_book_rounded, label: 'Library', index: 1, currentIndex: _currentIndex, onTap: _navigateTo),
                  _NavItem(icon: Icons.calendar_today_outlined, activeIcon: Icons.calendar_today_rounded, label: 'Events', index: 2, currentIndex: _currentIndex, onTap: _navigateTo),
                  _NavItem(icon: Icons.emoji_events_outlined, activeIcon: Icons.emoji_events_rounded, label: 'Achievement', index: 3, currentIndex: _currentIndex, onTap: _navigateTo),
                  _NavItem(icon: Icons.person_outline_rounded, activeIcon: Icons.person_rounded, label: 'Profile', index: 4, currentIndex: _currentIndex, onTap: _navigateTo),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon, activeIcon;
  final String label;
  final int index, currentIndex;
  final void Function(int) onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.index,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = index == currentIndex;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              active ? activeIcon : icon,
              color: active ? AppColors.primary : AppColors.textLight,
              size: 22,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: active ? AppColors.primary : AppColors.textLight,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 3),
            if (active)
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
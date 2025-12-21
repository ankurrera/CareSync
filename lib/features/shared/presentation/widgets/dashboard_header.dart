import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../routing/route_names.dart';
import '../../../auth/providers/auth_provider.dart';

class DashboardHeader extends ConsumerWidget {
  final String greeting;
  final String name;
  final String subtitle;
  final Color roleColor;
  final VoidCallback onNotificationTap;
  final VoidCallback onProfileTap;

  const DashboardHeader({
    super.key,
    required this.greeting,
    required this.name,
    required this.subtitle,
    required this.roleColor,
    required this.onNotificationTap,
    required this.onProfileTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        // Profile Avatar
        GestureDetector(
          onTap: onProfileTap,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: roleColor.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(
                color: roleColor.withOpacity(0.3),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.person_rounded,
              color: roleColor,
              size: 28,
            ),
          ),
        ),
        const SizedBox(width: 14),
        // Greeting
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                greeting,
                style: TextStyle(
                  fontSize: 14,
                  color:
                      Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
              Text(
                name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        // Notification button
        IconButton(
          onPressed: onNotificationTap,
          icon: const Icon(Icons.notifications_outlined),
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.surface,
          ),
        ),
        // Sign out button
        IconButton(
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Sign Out'),
                content: const Text('Are you sure you want to sign out?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Sign Out'),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await ref.read(authNotifierProvider.notifier).signOut();
              if (context.mounted) {
                context.go(RouteNames.roleSelection);
              }
            }
          },
          icon: const Icon(Icons.logout_rounded),
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.surface,
          ),
        ),
      ],
    );
  }
}


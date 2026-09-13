import 'package:flutter/material.dart';

import '../../core/app_routes.dart';
import 'login_screen.dart';
import 'register_screen.dart';

abstract final class AuthRoutes {
  static const String login = AppRoutes.login;
  static const String register = AppRoutes.register;
}

class AuthRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AuthRoutes.login:
        return _fadeRoute(const LoginScreen());
      case AuthRoutes.register:
        return _fadeRoute(const RegisterScreen());
      default:
        return _fadeRoute(const LoginScreen());
    }
  }

  static PageRouteBuilder<T> _fadeRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          child: child,
        );
      },
    );
  }
}

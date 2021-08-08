import 'package:flutter/material.dart';
import '../pages/anime_page/anime_page.dart' as anime_page;
import '../pages/home_page/home_page.dart' as home_page;
import '../pages/manga_page/manga_page.dart' as manga_page;
import '../pages/search_page/search_page.dart' as search_page;
import '../pages/settings_page/settings_page.dart' as settings_page;
import '../pages/stacked_home_page/stacked_home_page.dart' as stacked_home_page;
import '../plugins/helpers/stater.dart' show SubscriberManager;
import '../plugins/translator/translator.dart';

abstract class RouteNames {
  static const String initialRoute = '/';

  static const String homeHandler = '/';
  static const String home = '/home';
  static const String search = '/search';
  static const String settings = '/settings';
  static const String animePage = '/anime_page';
  static const String mangaPage = '/manga_page';
}

class RouteInfo {
  RouteInfo({
    required final this.route,
    required final this.builder,
    final this.name,
    final this.icon,
    final this.isPublic = false,
    final this.alreadyHandled = false,
    final this.matcher,
  }) {
    if (isPublic) {
      if (icon == null) {
        throw ArgumentError("Public route ($route) didn't have an 'icon'");
      }
      if (name == null) {
        throw ArgumentError("Public route ($route) didn't have an 'name'");
      }
    }

    if (alreadyHandled && matcher != null) {
      throw ArgumentError("Already handled route can't have 'matcher'");
    }
  }

  final String route;
  final String Function()? name;
  final IconData? icon;
  final WidgetBuilder builder;
  final bool isPublic;
  final bool alreadyHandled;
  final bool Function(RouteSettings settings)? matcher;
}

class RouteKeeper extends NavigatorObserver {
  Route<dynamic>? currentRoute;
  final SubscriberManager<Route<dynamic>?> observer =
      SubscriberManager<Route<dynamic>?>();

  @override
  void didPush(
    final Route<dynamic> route,
    final Route<dynamic>? previousRoute,
  ) {
    currentRoute = route;
    observer.dispatch(route, previousRoute);
  }

  @override
  void didPop(final Route<dynamic> route, final Route<dynamic>? previousRoute) {
    currentRoute = previousRoute;
    observer.dispatch(previousRoute, route);
  }

  @override
  void didReplace({
    final Route<dynamic>? newRoute,
    final Route<dynamic>? oldRoute,
  }) {
    currentRoute = newRoute;
    observer.dispatch(newRoute, oldRoute);
  }
}

class ParsedRouteInfo {
  ParsedRouteInfo(this.route, this.params);

  final String route;
  final Map<String, String> params;

  @override
  String toString() => '$route?${RouteManager.makeURLParams(params)}';
}

abstract class RouteManager {
  static final GlobalKey<NavigatorState> navigationKey =
      GlobalKey<NavigatorState>();
  static final RouteKeeper keeper = RouteKeeper();
  static final Map<String, RouteInfo> routes = <String, RouteInfo>{
    RouteNames.home: RouteInfo(
      name: Translator.t.home,
      route: RouteNames.home,
      icon: Icons.home,
      builder: (final BuildContext context) => const home_page.Page(),
      isPublic: true,
      alreadyHandled: true,
    ),
    RouteNames.search: RouteInfo(
      name: Translator.t.search,
      route: RouteNames.search,
      icon: Icons.search,
      builder: (final BuildContext context) => const search_page.Page(),
      isPublic: true,
      alreadyHandled: true,
    ),
    RouteNames.settings: RouteInfo(
      name: Translator.t.settings,
      route: RouteNames.settings,
      icon: Icons.settings,
      builder: (final BuildContext context) => const settings_page.Page(),
      isPublic: true,
    ),
    RouteNames.animePage: RouteInfo(
      route: RouteNames.animePage,
      builder: (final BuildContext context) => const anime_page.Page(),
    ),
    RouteNames.mangaPage: RouteInfo(
      route: RouteNames.mangaPage,
      builder: (final BuildContext context) => const manga_page.Page(),
    ),
    RouteNames.homeHandler: RouteInfo(
      route: RouteNames.homeHandler,
      builder: (final BuildContext context) => const stacked_home_page.Page(),
      matcher: (final RouteSettings settings) =>
          settings.name?.startsWith(RouteNames.homeHandler) ?? false,
    ),
  };

  static List<RouteInfo> get labeledRoutes =>
      routes.values.where((final RouteInfo x) => x.isPublic).toList();

  static String getOnlyRoute(final String route) => route.split('?')[0];

  static ParsedRouteInfo parseRoute(final String route) {
    final List<String> split = route.split('?');
    return ParsedRouteInfo(
      split[0],
      parseURLParams(split.length > 1 ? split[1] : ''),
    );
  }

  static Map<String, String> parseURLParams(final String queries) {
    final Map<String, String> params = <String, String>{};
    queries.split('&').forEach((final String x) {
      final List<String> kv = x.split('=');
      if (kv.length == 2) {
        params[kv[0]] = Uri.decodeComponent(kv[1]);
      }
    });
    return params;
  }

  static String makeURLParams(final Map<String, String> queries) {
    final List<String> params = <String>[];
    queries.forEach((final String k, final String v) {
      params.add('$k=$v');
    });
    return params.join('&');
  }
}

import 'package:flutter/widgets.dart';

/// App-wide route observer.
///
/// Chat pages use it to tell SessionActivity whether their conversation is
/// actually the visible page. The app-level foreground flag alone is too
/// coarse: "foreground on the session list" or "foreground in another chat"
/// still needs the completion notification, while "foreground in this exact
/// chat" must not.
final RouteObserver<PageRoute<dynamic>> routeObserver =
    RouteObserver<PageRoute<dynamic>>();

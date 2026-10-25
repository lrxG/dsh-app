import 'package:flutter/cupertino.dart';

/// iOS-style push used by every conversation screen.
///
/// The app's global page-transitions theme already slid pages, but both the
/// list and the chat use the same grey background, so the outgoing list and
/// the incoming chat read as one flat sheet. This keeps the Cupertino push
/// (parallax, edge shadow, swipe-back) and adds a soft scrim over the page
/// underneath, so the two layers are unambiguous while they move.
///
/// It also trims the duration a little: 400 ms of slide feels sluggish on a
/// list with no large visuals to carry the motion.
class ChatRoute<T> extends CupertinoPageRoute<T> {
  ChatRoute({required super.builder, super.settings});

  /// Reverse transition length plus a frame; the list waits this long before
  /// refreshing on return, otherwise rows reorder while the page is still
  /// sliding back in underneath.
  static const Duration popSettle = Duration(milliseconds: 310);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 360);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Under the incoming page: darkens whatever is still visible of the
        // previous route. Fades back out on pop.
        IgnorePointer(
          child: FadeTransition(
            opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
            child: const ColoredBox(color: Color(0x0F000000)),
          ),
        ),
        super.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        ),
      ],
    );
  }
}

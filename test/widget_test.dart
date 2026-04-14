import 'package:flutter_test/flutter_test.dart';
import 'package:reposter/main.dart';

void main() {
  testWidgets('renders history-first home', (tester) async {
    await tester.pumpWidget(const ReposterApp());

    expect(find.text('Reposter'), findsOneWidget);
    expect(find.text('Paste Instagram or TikTok post link'), findsOneWidget);
    expect(
      find.text('Import a reel first and it will show up in history here.'),
      findsOneWidget,
    );
  });
}

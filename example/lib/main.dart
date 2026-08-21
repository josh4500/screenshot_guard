import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

void main() {
  runApp(
    ScreenshotShieldScope(
      shield: ScreenshotShield(),
      routeObserver: routeObserver,
      child: const MaterialApp(
        title: 'Screenshot Shield Demo',
        home: HomeScreen(),
      ),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScreenshotShield shield = ScreenshotShield();
  bool preventCapture = true;
  bool detectScreenshots = true;
  bool backgroundBlur = false;
  DateTime? lastDetected;
  Uint8List? lastImage;

  @override
  Widget build(BuildContext context) {
    return ScreenshotShieldRouteGuard(
      preventCapture: preventCapture,
      detectScreenshots: detectScreenshots,
      captureOnScreenshot: true,
      onScreenshotDetected: (image) {
        setState(() {
          lastDetected = DateTime.now();
          lastImage = image;
        });
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Screenshot Shield Demo')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionLabel('Guarded content'),
            Container(
              height: 180,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.indigo,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'This screen is protected.\nTry taking a screenshot.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Prevent capture'),
              subtitle: const Text(
                'Blanks the captured frame (Android and iOS)',
              ),
              value: preventCapture,
              onChanged: (value) => setState(() => preventCapture = value),
            ),
            SwitchListTile(
              title: const Text('Detect screenshots'),
              subtitle: const Text('Report onScreenshotDetected events'),
              value: detectScreenshots,
              onChanged: (value) => setState(() => detectScreenshots = value),
            ),
            SwitchListTile(
              title: const Text('Background blur'),
              subtitle: const Text('Blur the app in the app switcher'),
              value: backgroundBlur,
              onChanged: (value) async {
                setState(() => backgroundBlur = value);
                await shield.setProtection(backgroundBlur: value);
              },
            ),
            const SizedBox(height: 16),
            const _SectionLabel('Detection'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lastDetected == null
                          ? 'No screenshot detected yet.'
                          : 'Detected at ${lastDetected!.toLocal()}',
                    ),
                    if (lastImage != null) ...[
                      const SizedBox(height: 8),
                      Image.memory(
                        lastImage!,
                        height: 160,
                        fit: BoxFit.contain,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SecondScreen()),
              ),
              child: const Text('Open second screen (unprotect)'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class SecondScreen extends StatelessWidget {
  const SecondScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Second screen')),
      body: const Center(
        child: Text('This route is not guarded. Protection is released here.'),
      ),
    );
  }
}

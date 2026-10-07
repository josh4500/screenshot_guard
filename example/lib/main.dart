import 'dart:async';
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
  StreamSubscription<bool>? screenRecordingSubscription;
  bool preventCapture = true;
  bool detectScreenshots = true;
  bool backgroundBlur = false;
  DateTime? lastDetected;
  Uint8List? lastImage;
  bool isScreenRecording = false;
  int screenRecordingEvents = 0;

  @override
  void initState() {
    super.initState();
    // Read the current state first: the stream only delivers *changes*, so a screen
    // that appears while a recording is already running would otherwise show
    // "not recording" until the next change.
    isScreenRecording = shield.isScreenRecording;
    screenRecordingSubscription = shield.onScreenRecordingChanged.listen((
      value,
    ) {
      if (!mounted) {
        return;
      }
      setState(() {
        isScreenRecording = value;
        screenRecordingEvents++;
      });
    });
  }

  @override
  void dispose() {
    screenRecordingSubscription?.cancel();
    super.dispose();
  }

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
            const _SectionLabel('Screen recording'),
            Card(
              child: ListTile(
                leading: Icon(
                  isScreenRecording
                      ? Icons.fiber_manual_record
                      : Icons.videocam_off_outlined,
                  color: isScreenRecording ? Colors.red : null,
                ),
                title: Text(
                  isScreenRecording
                      ? 'The screen is being recorded'
                      : 'The screen is not being recorded',
                ),
                subtitle: Text(
                  'Android 15+, iOS (the iOS simulator always reports "not '
                  'recording"); best-effort on Windows and Linux · '
                  '${screenRecordingEvents == 0 ? 'no state events yet' : '$screenRecordingEvents state event(s)'}',
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SecondScreen()),
              ),
              child: const Text('Open region shielding demo'),
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

class SecondScreen extends StatefulWidget {
  const SecondScreen({super.key});

  @override
  State<SecondScreen> createState() => _SecondScreenState();
}

class _SecondScreenState extends State<SecondScreen> {
  final TextEditingController _text = TextEditingController();
  Timer? _ticker;
  int _seconds = 0;
  bool _alwaysProtect = false;

  @override
  void initState() {
    super.initState();
    // Something inside the region that keeps changing, to show that the copy the
    // user sees tracks the live subtree instead of freezing.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _seconds++);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Region shielding')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'By default this region is the original widget - nothing wrapped, '
            'nothing rasterised - and iOS only keeps it out of captures while the '
            'screen is recorded or mirrored, or while the app is in the background '
            '(which also keeps it out of the app-switcher snapshot).',
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('Always keep the region out of captures'),
            subtitle: const Text(
              'On: also blanks foreground screenshots, by showing a live copy of '
              'the subtree instead of the subtree itself',
            ),
            value: _alwaysProtect,
            onChanged: (value) => setState(() => _alwaysProtect = value),
          ),
          const Text('Ordinary content (captured normally):'),
          const SizedBox(height: 8),
          Container(
            height: 64,
            alignment: Alignment.center,
            color: Colors.teal,
            child: const Text(
              'Ordinary content',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Sensitive region:'),
          const SizedBox(height: 8),
          ScreenshotShieldSensitiveView(
            protection: _alwaysProtect
                ? SensitiveProtection.always
                : SensitiveProtection.whileCaptured,
            // What a capture shows, and what the user sees behind the copy.
            captureColor: Colors.black,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.deepOrange,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Live counter: $_seconds s · Expires 09/29',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _text,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: Colors.white,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Tap and type: input works normally',
                      hintStyle: TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white54),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Try it: the counter ticks and typing works. Start a screen recording '
            'from Control Center and this region comes out black in the recording '
            'while the app on screen keeps showing it; background the app and the '
            'app-switcher card is black too. A foreground screenshot is not covered '
            'unless the switch above is on - screens that must come out blank use '
            'whole-window prevention, which is what the home screen of this demo '
            'does.',
          ),
        ],
      ),
    );
  }
}

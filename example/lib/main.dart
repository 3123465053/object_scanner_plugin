import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:object_scanner_plugin/object_scanner_plugin.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';

void main() {
  configLoading();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';
  final _objectScannerPlugin = ObjectScannerPlugin();

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    String platformVersion;
    // Platform messages may fail, so we use a try/catch PlatformException.
    // We also handle the message potentially returning null.
    try {
      platformVersion =
          await _objectScannerPlugin.getPlatformVersion() ??
          'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Plugin example app')),
        body: Center(
          child: Column(
            children: [
              Text('Running on: $_platformVersion\n'),
              ElevatedButton(
                onPressed: () async {
                  try {
                    EasyLoading.show(status: "loading...");
                    var res = await _objectScannerPlugin.startScannerObject();
                    EasyLoading.dismiss();
                    print("sfsfsss");
                    print(res);
                  } catch (e) {
                    print("sfdd");
                    print(e);
                    EasyLoading.dismiss();
                  }
                },
                child: Text("开始扫描"),
              ),
            ],
          ),
        ),
      ),
      builder: EasyLoading.init(builder: (context, widget) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaleFactor: 1.0),
          child: widget!,
        );
      }),
    );
  }
}

void configLoading() {
  EasyLoading.instance
    ..indicatorType = EasyLoadingIndicatorType.fadingCircle
    ..loadingStyle = EasyLoadingStyle.custom
    ..radius = 10.0
    ..progressColor = Colors.black
    ..backgroundColor = Colors.grey.shade200
    ..indicatorColor = Color(0xff000000)
    ..textColor = Color(0xff000000)
    ..userInteractions = false
    ..dismissOnTap = false
    ..animationStyle = EasyLoadingAnimationStyle.scale;
}

import 'package:flutter_test/flutter_test.dart';
import 'package:object_scanner_plugin/object_scanner_plugin.dart';
import 'package:object_scanner_plugin/object_scanner_plugin_platform_interface.dart';
import 'package:object_scanner_plugin/object_scanner_plugin_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockObjectScannerPluginPlatform
    with MockPlatformInterfaceMixin
    implements ObjectScannerPluginPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool?> startScannerObject() {
    // TODO: implement startScanner
    throw UnimplementedError();
  }

  @override
  startScannerRoom() {
    // TODO: implement startScannerRoom
    throw UnimplementedError();
  }
}

void main() {
  final ObjectScannerPluginPlatform initialPlatform = ObjectScannerPluginPlatform.instance;

  test('$MethodChannelObjectScannerPlugin is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelObjectScannerPlugin>());
  });

  test('getPlatformVersion', () async {
    ObjectScannerPlugin objectScannerPlugin = ObjectScannerPlugin();
    MockObjectScannerPluginPlatform fakePlatform = MockObjectScannerPluginPlatform();
    ObjectScannerPluginPlatform.instance = fakePlatform;

    expect(await objectScannerPlugin.getPlatformVersion(), '42');
  });
}

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:object_scanner_plugin/object_scanner_plugin.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:file_picker/file_picker.dart';

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
  String? path="";
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
      home: Builder(
        builder: (ctx) => Scaffold(
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
                      print(res);
                      setState(() { path = res["path"]; });
                    } catch (e) {
                      print(e);
                      EasyLoading.dismiss();
                    }
                  },
                  child: Text("开始扫描"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      EasyLoading.show(status: "loading...");
                      var res = await _objectScannerPlugin.startScannerRoom();
                      EasyLoading.dismiss();
                      print(res);
                      setState(() { path = res["path"]; });
                    } catch (e) {
                      print(e);
                      EasyLoading.dismiss();
                    }
                  },
                  child: Text("扫描房间"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      EasyLoading.show(status: "loading...");
                      var res = await _objectScannerPlugin.startScannerSpace();
                      EasyLoading.dismiss();
                      print(res);
                      setState(() { path = res["path"]; });
                    } catch (e) {
                      print(e);
                      EasyLoading.dismiss();
                    }
                  },
                  child: Text("扫描空间"),
                ),

                if (path != null && path!.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    height: 400,
                    child: UiKitView(
                      key: ValueKey(path),
                      viewType: "swift_ui_view",
                      onPlatformViewCreated: (id) {
                        MethodChannel('swift_ui_view_$id')
                            .invokeMethod('setParams', {'view_type': 'usdz_preview_view', 'path': path});
                      },
                      creationParamsCodec: StandardMessageCodec(),
                    ),
                  ),

                ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).push(
                      MaterialPageRoute(builder: (_) => FormatConvertTestPage(plugin: _objectScannerPlugin)),
                    );
                  },
                  child: Text("格式转换测试"),
                ),
              ],
            ),
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

// ── 格式转换测试页面 ──────────────────────────────────────────────────
class FormatConvertTestPage extends StatefulWidget {
  final ObjectScannerPlugin plugin;
  const FormatConvertTestPage({super.key, required this.plugin});

  @override
  State<FormatConvertTestPage> createState() => _FormatConvertTestPageState();
}

class _FormatConvertTestPageState extends State<FormatConvertTestPage> {
  String? _inputPath;
  String? _inputFileName;
  String _selectedFormat = 'obj';
  String? _previewPath;  // 当前预览的文件路径
  final List<String> _formats = [
    'obj', 'stl', 'ply', 'usd', 'usda', 'usdc',
    'usdz', 'scn', 'glb', 'gltf',
  ];
  // 每条结果额外存 path 用于预览
  final List<Map<String, String>> _results = [];

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null && result.files.single.path != null) {
      setState(() {
        _inputPath = result.files.single.path;
        _inputFileName = result.files.single.name;
      });
    }
  }

  Future<void> _scanForInput() async {
    try {
      EasyLoading.show(status: "扫描中...");
      var res = await widget.plugin.startScannerObject();
      EasyLoading.dismiss();
      if (res != null && res["path"] != null) {
        setState(() {
          _inputPath = res["path"];
          _inputFileName = _inputPath!.split('/').last;
        });
      }
    } catch (e) {
      EasyLoading.dismiss();
      _addResult("扫描", "失败: $e", null);
    }
  }

  Future<void> _convert(String format) async {
    if (_inputPath == null || _inputPath!.isEmpty) {
      _addResult(format, "请先选择输入文件", null);
      return;
    }
    try {
      EasyLoading.show(status: "转换为 $format ...");
      var res = await widget.plugin.convertFormat(_inputPath!, format);
      EasyLoading.dismiss();
      final msg = res["msg"] ?? "unknown";
      final path = res["path"] as String?;
      if (msg == "success" && path != null) {
        _addResult(format, "成功: ${path.split('/').last}", path);
      } else {
        _addResult(format, "失败: $msg", null);
      }
    } catch (e) {
      EasyLoading.dismiss();
      _addResult(format, "异常: $e", null);
    }
  }

  Future<void> _convertAll() async {
    for (final fmt in _formats) {
      await _convert(fmt);
    }
  }

  void _addResult(String format, String msg, String? outputPath) {
    setState(() {
      _results.insert(0, {"format": format, "msg": msg, if (outputPath != null) "path": outputPath});
    });
  }

  void _preview(String path) {
    setState(() {
      // 用不同 key 强制重建 UiKitView
      _previewPath = _previewPath == path ? null : path;
    });
    // 如果关闭后再点，重新打开
    if (_previewPath == null) {
      Future.microtask(() => setState(() => _previewPath = path));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("格式转换测试")),
      body: Column(
        children: [
          // ── 输入文件 ──
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.grey.shade100,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("输入文件:", style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  _inputFileName ?? "未选择",
                  style: TextStyle(fontSize: 12, color: _inputPath != null ? Colors.black : Colors.red),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                ),
                if (_inputPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(_inputPath!, style: TextStyle(fontSize: 10, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton.icon(onPressed: _pickFile, icon: Icon(Icons.folder_open, size: 18), label: Text("选择文件")),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(onPressed: _scanForInput, icon: Icon(Icons.view_in_ar, size: 18), label: Text("扫描获取")),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ── 格式选择 + 转换 ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text("输出: "),
                DropdownButton<String>(
                  value: _selectedFormat,
                  items: _formats.map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
                  onChanged: (v) => setState(() => _selectedFormat = v!),
                ),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: () => _convert(_selectedFormat), child: Text("转换")),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _convertAll,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  child: Text("全部测试", style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ── 3D 预览区域 ──
          if (_previewPath != null)
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  color: Colors.blue.shade50,
                  child: Row(
                    children: [
                      Icon(Icons.visibility, size: 16, color: Colors.blue),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text("预览: ${_previewPath!.split('/').last}",
                            style: TextStyle(fontSize: 12, color: Colors.blue.shade800),
                            overflow: TextOverflow.ellipsis),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(),
                        onPressed: () => setState(() => _previewPath = null),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  height: 280,
                  child: UiKitView(
                    key: ValueKey(_previewPath),
                    viewType: "swift_ui_view",
                    onPlatformViewCreated: (id) {
                      MethodChannel('swift_ui_view_$id')
                          .invokeMethod('setParams', {'view_type': 'usdz_preview_view', 'path': _previewPath});
                    },
                    creationParamsCodec: StandardMessageCodec(),
                  ),
                ),
                const Divider(height: 1),
              ],
            ),
          // ── 结果列表 ──
          Expanded(
            child: _results.isEmpty
                ? Center(child: Text("暂无转换结果", style: TextStyle(color: Colors.grey)))
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final ok = r["msg"]!.startsWith("成功");
                      final hasPath = r.containsKey("path");
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          ok ? Icons.check_circle : Icons.error,
                          color: ok ? Colors.green : Colors.red,
                          size: 20,
                        ),
                        title: Text(r["format"]!.toUpperCase(),
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        subtitle: Text(r["msg"]!, style: TextStyle(fontSize: 11), maxLines: 2),
                        trailing: hasPath
                            ? IconButton(
                                icon: Icon(Icons.visibility, color: Colors.blue, size: 22),
                                tooltip: "预览",
                                onPressed: () => _preview(r["path"]!),
                              )
                            : null,
                        onTap: hasPath ? () => _preview(r["path"]!) : null,
                      );
                    },
                  ),
          ),
        ],
      ),
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

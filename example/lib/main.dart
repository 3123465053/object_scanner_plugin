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
  String? path = "";

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion =
          await _objectScannerPlugin.getPlatformVersion() ??
          'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }
    if (!mounted) return;
    setState(() => _platformVersion = platformVersion);
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
                  child: const Text("开始扫描"),
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
                  child: const Text("扫描房间"),
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
                  child: const Text("扫描空间"),
                ),

                if (path != null && path!.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    height: 400,
                    child: UiKitView(
                      key: ValueKey(path),
                      viewType: "swift_ui_view",
                      onPlatformViewCreated: (id) {
                        MethodChannel('swift_ui_view_$id').invokeMethod(
                            'setParams',
                            {'view_type': 'usdz_preview_view', 'path': path});
                      },
                      creationParamsCodec: const StandardMessageCodec(),
                    ),
                  ),

                ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).push(
                      MaterialPageRoute(
                          builder: (_) => FormatConvertTestPage(
                              plugin: _objectScannerPlugin)),
                    );
                  },
                  child: const Text("格式转换测试"),
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
  String? _previewPath;

  final List<String> _formats = [
    'obj', 'stl', 'ply', 'usd', 'usda', 'usdc',
    'usdz', 'scn', 'glb', 'gltf',
  ];

  // 转换结果列表
  final List<Map<String, String>> _results = [];

  // 后台转换状态
  StreamSubscription<Map<String, dynamic>>? _resultSub;
  final Set<String> _converting = {};         // 正在转换的格式名
  final Map<String, String> _jobToFormat = {}; // jobId → format

  // ── 生命周期 ──────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // 订阅后台转换结果流
    _resultSub = widget.plugin.conversionResultStream.listen(_onConversionResult);
  }

  @override
  void dispose() {
    _resultSub?.cancel();
    super.dispose();
  }

  // ── 后台结果回调 ──────────────────────────────────────────────────

  void _onConversionResult(Map<String, dynamic> event) {
    final jobId  = event['jobId']  as String?  ?? '';
    final format = _jobToFormat.remove(jobId);
    if (format == null) return; // 非本页发起的任务

    final msg  = event['msg']  as String? ?? 'unknown';
    final path = event['path'] as String?;

    setState(() {
      _converting.remove(format);
      if (msg == 'success' && path != null) {
        _addResult(format, '成功: ${path.split('/').last}', path);
      } else {
        _addResult(format, '失败: $msg', null);
      }
    });
  }

  // ── 操作 ──────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null && result.files.single.path != null) {
      setState(() {
        _inputPath = result.files.single.path;
        _inputFileName = result.files.single.name;
        // 切换文件时清空旧结果
        _results.clear();
        _converting.clear();
        _jobToFormat.clear();
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
          _results.clear();
          _converting.clear();
          _jobToFormat.clear();
        });
      }
    } catch (e) {
      EasyLoading.dismiss();
      _addResult("扫描", "失败: $e", null);
    }
  }

  /// 启动单个格式的后台转换（立即返回，不阻塞 UI）
  Future<void> _convert(String format) async {
    if (_inputPath == null || _inputPath!.isEmpty) {
      _addResult(format, "请先选择输入文件", null);
      return;
    }
    if (_converting.contains(format)) return;
    setState(() => _converting.add(format));
    try {
      final jobId = await widget.plugin.startConvertFormatBg(_inputPath!, format);
      _jobToFormat[jobId] = format;
    } catch (e) {
      setState(() {
        _converting.remove(format);
        _addResult(format, '启动失败: $e', null);
      });
    }
  }

  /// 全部测试：立即把所有格式投入 iOS 串行队列，Flutter 不等待
  /// iOS conversionQueue 保证同一时刻只跑一个，Scene 缓存对后续格式生效
  /// Flutter 侧可同时看到所有格式的 "转换中" chip
  Future<void> _convertAll() async {
    if (_inputPath == null || _inputPath!.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("请先选择输入文件")));
      return;
    }
    for (final fmt in _formats) {
      await _convert(fmt); // _convert 立即返回（只发消息，不等结果）
    }
  }

  void _addResult(String format, String msg, String? outputPath) {
    // 同一格式的新结果插到顶部（移除旧的）
    _results.removeWhere((r) => r['format'] == format);
    _results.insert(0, {
      'format': format,
      'msg': msg,
      if (outputPath != null) 'path': outputPath,
    });
  }

  void _preview(String path) {
    setState(() {
      _previewPath = _previewPath == path ? null : path;
    });
    if (_previewPath == null) {
      Future.microtask(() => setState(() => _previewPath = path));
    }
  }

  Future<void> _export(String path) async {
    try {
      var res = await widget.plugin.exportFile(path);
      final msg = res?["msg"] ?? "unknown";
      if (msg == "success") {
        EasyLoading.showSuccess("导出成功");
      } else if (msg != "已取消") {
        EasyLoading.showError("导出失败: $msg");
      }
    } catch (e) {
      EasyLoading.showError("导出异常: $e");
    }
  }

  // ── UI ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final doneCount  = _results.length;
    final totalCount = _converting.length + doneCount;

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
                const Text("输入文件:", style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  _inputFileName ?? "未选择",
                  style: TextStyle(
                      fontSize: 12,
                      color: _inputPath != null ? Colors.black : Colors.red),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (_inputPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(_inputPath!,
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton.icon(
                        onPressed: _pickFile,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text("选择文件")),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                        onPressed: _scanForInput,
                        icon: const Icon(Icons.view_in_ar, size: 18),
                        label: const Text("扫描获取")),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ── 格式选择 + 转换按钮 ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text("输出: "),
                DropdownButton<String>(
                  value: _selectedFormat,
                  items: _formats
                      .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedFormat = v!),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _convert(_selectedFormat),
                  child: const Text("转换"),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _convertAll,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  child: const Text("全部测试",
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),

          // ── 后台进度条：有转换中的格式时显示 ──
          if (_converting.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: Colors.blue.shade50,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "后台转换中：$doneCount / $totalCount 完成",
                        style: TextStyle(
                            fontSize: 12, color: Colors.blue.shade800),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 正在转换的格式 chip
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: _converting
                        .map((f) => Chip(
                              label: Text(f.toUpperCase(),
                                  style: const TextStyle(fontSize: 11)),
                              avatar: const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white),
                              ),
                              backgroundColor: Colors.blue.shade300,
                              labelStyle:
                                  const TextStyle(color: Colors.white),
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                            ))
                        .toList(),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  color: Colors.blue.shade50,
                  child: Row(
                    children: [
                      const Icon(Icons.visibility,
                          size: 16, color: Colors.blue),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          "预览: ${_previewPath!.split('/').last}",
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue.shade800),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
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
                      MethodChannel('swift_ui_view_$id').invokeMethod(
                          'setParams',
                          {'view_type': 'usdz_preview_view', 'path': _previewPath});
                    },
                    creationParamsCodec: const StandardMessageCodec(),
                  ),
                ),
                const Divider(height: 1),
              ],
            ),

          // ── 结果列表 ──
          Expanded(
            child: _results.isEmpty && _converting.isEmpty
                ? const Center(
                    child: Text("暂无转换结果",
                        style: TextStyle(color: Colors.grey)))
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r      = _results[i];
                      final ok     = r["msg"]!.startsWith("成功");
                      final hasPath = r.containsKey("path");
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          ok ? Icons.check_circle : Icons.error,
                          color: ok ? Colors.green : Colors.red,
                          size: 20,
                        ),
                        title: Text(r["format"]!.toUpperCase(),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                        subtitle: Text(r["msg"]!,
                            style: const TextStyle(fontSize: 11),
                            maxLines: 2),
                        trailing: hasPath
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.visibility,
                                        color: Colors.blue, size: 22),
                                    tooltip: "预览",
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () => _preview(r["path"]!),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(Icons.ios_share,
                                        color: Colors.green, size: 22),
                                    tooltip: "导出",
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () => _export(r["path"]!),
                                  ),
                                ],
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
    ..indicatorColor = const Color(0xff000000)
    ..textColor = const Color(0xff000000)
    ..userInteractions = false
    ..dismissOnTap = false
    ..animationStyle = EasyLoadingAnimationStyle.scale;
}

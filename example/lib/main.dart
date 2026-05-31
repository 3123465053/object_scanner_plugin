import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:object_scanner_plugin/object_scanner_plugin.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:file_picker/file_picker.dart';

import 'l10n.dart';

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
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomePage(),
      builder: EasyLoading.init(builder: (context, widget) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaleFactor: 1.0),
          child: widget!,
        );
      }),
    );
  }
}

// ── 主页 ─────────────────────────────────────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
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
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Builder(
        builder: (ctx) => Center(
          child: Column(
            children: [
              Text('${l10n.runningOn}$_platformVersion\n'),
              ElevatedButton(
                onPressed: () async {
                  try {
                    EasyLoading.show(status: l10n.loading);
                    var res = await _objectScannerPlugin.startScannerObject();
                    EasyLoading.dismiss();
                    setState(() { path = res["path"]; });
                  } catch (e) {
                    EasyLoading.dismiss();
                  }
                },
                child: Text(l10n.startScan),
              ),
              ElevatedButton(
                onPressed: () async {
                  try {
                    EasyLoading.show(status: l10n.loading);
                    var res = await _objectScannerPlugin.startScannerRoom();
                    EasyLoading.dismiss();
                    setState(() { path = res["path"]; });
                  } catch (e) {
                    EasyLoading.dismiss();
                  }
                },
                child: Text(l10n.scanRoom),
              ),
              ElevatedButton(
                onPressed: () async {
                  try {
                    EasyLoading.show(status: l10n.loading);
                    var res = await _objectScannerPlugin.startScannerSpace();
                    EasyLoading.dismiss();
                    setState(() { path = res["path"]; });
                  } catch (e) {
                    EasyLoading.dismiss();
                  }
                },
                child: Text(l10n.scanSpace),
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
                child: Text(l10n.formatConvertTest),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.view_in_ar_rounded),
                label: Text(l10n.arPreviewTest),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  Navigator.of(ctx).push(
                    MaterialPageRoute(
                        builder: (_) => ARPreviewTestPage(
                            plugin: _objectScannerPlugin)),
                  );
                },
              ),
            ],
          ),
        ),
      ),
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

class _ConversionResult {
  final String format;
  final bool isSuccess;
  final String? outputPath;
  final String nativeMsg;
  _ConversionResult({
    required this.format,
    required this.isSuccess,
    this.outputPath,
    required this.nativeMsg,
  });
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

  final List<_ConversionResult> _results = [];

  StreamSubscription<Map<String, dynamic>>? _resultSub;
  final Set<String> _converting = {};
  final Map<String, String> _jobToFormat = {};

  @override
  void initState() {
    super.initState();
    _resultSub = widget.plugin.conversionResultStream.listen(_onConversionResult);
  }

  @override
  void dispose() {
    _resultSub?.cancel();
    super.dispose();
  }

  void _onConversionResult(Map<String, dynamic> event) {
    if (!mounted) return;
    final jobId  = event['jobId']  as String?  ?? '';
    final format = _jobToFormat.remove(jobId);
    if (format == null) return;

    final msg  = event['msg']  as String? ?? 'unknown';
    final path = event['path'] as String?;

    setState(() {
      _converting.remove(format);
      _addResult(_ConversionResult(
        format: format,
        isSuccess: msg == 'success' && path != null,
        outputPath: path,
        nativeMsg: msg,
      ));
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null && result.files.single.path != null) {
      setState(() {
        _inputPath = result.files.single.path;
        _inputFileName = result.files.single.name;
        _results.clear();
        _converting.clear();
        _jobToFormat.clear();
      });
    }
  }

  Future<void> _scanForInput() async {
    final l10n = AppLocalizations.of(context);
    try {
      EasyLoading.show(status: l10n.scanning);
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
      if (mounted) {
        _addResult(_ConversionResult(
          format: AppLocalizations.of(context).scanning,
          isSuccess: false,
          nativeMsg: e.toString(),
        ));
      }
    }
  }

  Future<void> _convert(String format) async {
    if (_inputPath == null || _inputPath!.isEmpty) {
      _addResult(_ConversionResult(format: format, isSuccess: false, nativeMsg: 'no_input'));
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
        _addResult(_ConversionResult(format: format, isSuccess: false, nativeMsg: 'start_failed:${e.toString()}'));
      });
    }
  }

  Future<void> _convertAll() async {
    if (_inputPath == null || _inputPath!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).selectInputFirst)));
      return;
    }
    for (final fmt in _formats) {
      await _convert(fmt);
    }
  }

  void _addResult(_ConversionResult result) {
    _results.removeWhere((r) => r.format == result.format);
    _results.insert(0, result);
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
    final l10n = AppLocalizations.of(context);
    try {
      var res = await widget.plugin.exportFile(path);
      final msg = res?["msg"] ?? "unknown";
      if (msg == "success") {
        EasyLoading.showSuccess(l10n.exportSuccess);
      } else if (msg != "cancelled") {
        EasyLoading.showError(l10n.exportFailed(msg));
      }
    } catch (e) {
      EasyLoading.showError(l10n.exportError(e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final doneCount  = _results.length;
    final totalCount = _converting.length + doneCount;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.formatConvertTitle)),
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
                Text(l10n.inputFile, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  _inputFileName ?? l10n.notSelected,
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
                        label: Text(l10n.chooseFile)),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                        onPressed: _scanForInput,
                        icon: const Icon(Icons.view_in_ar, size: 18),
                        label: Text(l10n.scanForInput)),
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
                Text(l10n.output),
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
                  child: Text(l10n.convert),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _convertAll,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  child: Text(l10n.testAll,
                      style: const TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),

          // ── 后台进度条 ──
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
                        l10n.bgConverting(doneCount, totalCount),
                        style: TextStyle(
                            fontSize: 12, color: Colors.blue.shade800),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
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
                          l10n.previewFile(_previewPath!.split('/').last),
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
                ? Center(
                    child: Text(l10n.noResults,
                        style: const TextStyle(color: Colors.grey)))
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final displayMsg = r.isSuccess
                          ? l10n.successMsg(r.outputPath!.split('/').last)
                          : r.nativeMsg == 'no_input'
                              ? l10n.selectInputFirst
                              : r.nativeMsg.startsWith('start_failed:')
                                  ? l10n.startFailedMsg(r.nativeMsg.substring(13))
                                  : l10n.failedMsg(r.nativeMsg);
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          r.isSuccess ? Icons.check_circle : Icons.error,
                          color: r.isSuccess ? Colors.green : Colors.red,
                          size: 20,
                        ),
                        title: Text(r.format.toUpperCase(),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                        subtitle: Text(displayMsg,
                            style: const TextStyle(fontSize: 11),
                            maxLines: 2),
                        trailing: r.isSuccess && r.outputPath != null
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.visibility,
                                        color: Colors.blue, size: 22),
                                    tooltip: l10n.preview,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () => _preview(r.outputPath!),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(Icons.ios_share,
                                        color: Colors.green, size: 22),
                                    tooltip: l10n.export,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () => _export(r.outputPath!),
                                  ),
                                ],
                              )
                            : null,
                        onTap: r.isSuccess && r.outputPath != null
                            ? () => _preview(r.outputPath!)
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── AR 预览测试页面 ───────────────────────────────────────────────────
class ARPreviewTestPage extends StatefulWidget {
  final ObjectScannerPlugin plugin;
  const ARPreviewTestPage({super.key, required this.plugin});

  @override
  State<ARPreviewTestPage> createState() => _ARPreviewTestPageState();
}

class _ARPreviewTestPageState extends State<ARPreviewTestPage> {
  String? _usdzPath;
  String? _usdzName;
  late String _status;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _status = AppLocalizations.of(context).noFileSelected;
  }

  Future<void> _pickUSDZ() async {
    final l10n = AppLocalizations.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['usdz', 'usd', 'usda', 'usdc'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _usdzPath = result.files.single.path;
        _usdzName = result.files.single.name;
        _status = l10n.selectedFile(_usdzName!);
      });
    }
  }

  Future<void> _scanForUSDZ() async {
    final l10n = AppLocalizations.of(context);
    setState(() { _loading = true; _status = l10n.scanning; });
    try {
      EasyLoading.show(status: l10n.scanning);
      final res = await widget.plugin.startScannerObject();
      EasyLoading.dismiss();
      final p = res?['path'] as String?;
      if (p != null && p.isNotEmpty) {
        setState(() {
          _usdzPath = p;
          _usdzName = p.split('/').last;
          _status = l10n.scanComplete(_usdzName!);
        });
      } else {
        setState(() => _status = l10n.scanCancelledOrFailed);
      }
    } catch (e) {
      EasyLoading.dismiss();
      setState(() => _status = l10n.scanError(e.toString()));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _launchAR() async {
    final l10n = AppLocalizations.of(context);
    if (_usdzPath == null) {
      setState(() => _status = l10n.selectOrScanUSDZFirst);
      return;
    }
    setState(() { _loading = true; _status = l10n.processing; });
    try {
      final res = await widget.plugin.openARQuickLook(_usdzPath!);
      final msg = res?['msg'] as String? ?? 'unknown';
      setState(() => _status = l10n.arEnded(msg));
    } catch (e) {
      setState(() => _status = l10n.arError(e.toString()));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.arPreviewTitle)),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── 状态卡片 ──
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.status, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  Text(_status, style: const TextStyle(fontSize: 12, color: Colors.black87)),
                  if (_usdzPath != null) ...[
                    const SizedBox(height: 4),
                    Text(_usdzPath!,
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── 获取文件 ──
            Text(l10n.step1,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _loading ? null : _pickUSDZ,
                    icon: const Icon(Icons.folder_open),
                    label: Text(l10n.chooseFromFiles),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _loading ? null : _scanForUSDZ,
                    icon: const Icon(Icons.document_scanner),
                    label: Text(l10n.scanForInput),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.teal,
                        foregroundColor: Colors.white),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 32),

            // ── AR 预览 ──
            Text(l10n.step2,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 10),

            SizedBox(
              height: 54,
              child: ElevatedButton.icon(
                onPressed: (_loading || _usdzPath == null) ? null : _launchAR,
                icon: _loading
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.view_in_ar_rounded, size: 24),
                label: Text(
                  _loading ? l10n.processing : l10n.arPreview,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ── 说明 ──
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                l10n.arTip,
                style: const TextStyle(fontSize: 11, color: Colors.black54, height: 1.5),
              ),
            ),
          ],
        ),
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

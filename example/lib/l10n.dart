import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;
  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const delegate = _AppLocalizationsDelegate();

  bool get _isChinese => locale.languageCode == 'zh';

  // ── 通用 ──
  String get appTitle => _isChinese ? 'Plugin 示例应用' : 'Plugin Example App';
  String get loading => _isChinese ? '加载中...' : 'Loading...';
  String get scanning => _isChinese ? '扫描中...' : 'Scanning...';
  String get processing => _isChinese ? '处理中...' : 'Processing...';
  String get cancel => _isChinese ? '已取消' : 'Cancelled';

  // ── 主页 ──
  String get runningOn => _isChinese ? '运行平台：' : 'Running on: ';
  String get startScan => _isChinese ? '开始扫描' : 'Start Scan';
  String get scanRoom => _isChinese ? '扫描房间' : 'Scan Room';
  String get scanSpace => _isChinese ? '扫描空间' : 'Scan Space';
  String get formatConvertTest => _isChinese ? '格式转换测试' : 'Format Convert Test';
  String get arPreviewTest => _isChinese ? 'AR 预览测试' : 'AR Preview Test';

  // ── 格式转换页 ──
  String get formatConvertTitle => _isChinese ? '格式转换测试' : 'Format Convert';
  String get inputFile => _isChinese ? '输入文件:' : 'Input File:';
  String get notSelected => _isChinese ? '未选择' : 'Not Selected';
  String get chooseFile => _isChinese ? '选择文件' : 'Choose File';
  String get scanForInput => _isChinese ? '扫描获取' : 'Scan';
  String get output => _isChinese ? '输出: ' : 'Output: ';
  String get convert => _isChinese ? '转换' : 'Convert';
  String get testAll => _isChinese ? '全部测试' : 'Test All';
  String get noResults => _isChinese ? '暂无转换结果' : 'No conversion results';
  String get selectInputFirst => _isChinese ? '请先选择输入文件' : 'Please select an input file first';
  String get preview => _isChinese ? '预览' : 'Preview';
  String get export => _isChinese ? '导出' : 'Export';
  String get exportSuccess => _isChinese ? '导出成功' : 'Export successful';
  String get success => _isChinese ? '成功' : 'Success';
  String get failed => _isChinese ? '失败' : 'Failed';
  String get startFailed => _isChinese ? '启动失败' : 'Start failed';

  String bgConverting(int done, int total) => _isChinese
      ? '后台转换中：$done / $total 完成'
      : 'Converting: $done / $total done';

  String previewFile(String name) => _isChinese ? '预览: $name' : 'Preview: $name';

  String exportFailed(String msg) => _isChinese ? '导出失败: $msg' : 'Export failed: $msg';
  String exportError(String e) => _isChinese ? '导出异常: $e' : 'Export error: $e';

  String successMsg(String name) => _isChinese ? '成功: $name' : 'Success: $name';
  String failedMsg(String msg) => _isChinese ? '失败: $msg' : 'Failed: $msg';
  String startFailedMsg(String e) => _isChinese ? '启动失败: $e' : 'Start failed: $e';
  String scanFailedMsg(String e) => _isChinese ? '失败: $e' : 'Failed: $e';

  // ── AR 预览页 ──
  String get arPreviewTitle => _isChinese ? 'AR 预览测试' : 'AR Preview Test';
  String get noFileSelected => _isChinese ? '尚未选择文件' : 'No file selected';
  String get status => _isChinese ? '状态' : 'Status';
  String get step1 => _isChinese ? '第一步：获取 USDZ 文件' : 'Step 1: Get USDZ File';
  String get chooseFromFiles => _isChinese ? '从文件选择' : 'Choose from Files';
  String get step2 => _isChinese ? '第二步：启动 AR 预览' : 'Step 2: Launch AR Preview';
  String get arPreview => _isChinese ? 'AR 预览' : 'AR Preview';
  String get arTip => _isChinese
      ? '原理：通过 WKWebView 的 rel="ar" 锚点直接触发 iOS AR Quick Look，\n完全跳过 QLPreviewController 底部 sheet 预览，与系统原生体验一致。'
      : 'Uses WKWebView\'s rel="ar" anchor to trigger iOS AR Quick Look directly,\nskipping the QLPreviewController bottom sheet for a native AR experience.';
  String get selectOrScanUSDZFirst =>
      _isChinese ? '请先选择或扫描一个 USDZ 文件' : 'Please select or scan a USDZ file first';

  String selectedFile(String name) => _isChinese ? '已选择：$name' : 'Selected: $name';
  String scanComplete(String name) => _isChinese ? '扫描完成：$name' : 'Scan complete: $name';
  String get scanCancelledOrFailed => _isChinese ? '扫描取消或失败' : 'Scan cancelled or failed';
  String arEnded(String msg) => _isChinese ? 'AR 结束：$msg' : 'AR ended: $msg';
  String arError(String e) => _isChinese ? 'AR 异常：$e' : 'AR error: $e';
  String scanError(String e) => _isChinese ? '扫描异常：$e' : 'Scan error: $e';
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      ['en', 'zh'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

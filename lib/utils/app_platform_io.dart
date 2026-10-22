import 'dart:io' as io;

/// Drop-in for dart:io's Platform. Pure pass-through on every non-web target.
class Platform {
  Platform._();

  static bool get isAndroid => io.Platform.isAndroid;
  static bool get isIOS => io.Platform.isIOS;
  static bool get isMacOS => io.Platform.isMacOS;
  static bool get isWindows => io.Platform.isWindows;
  static bool get isLinux => io.Platform.isLinux;
  static bool get isFuchsia => io.Platform.isFuchsia;
  static String get operatingSystem => io.Platform.operatingSystem;
  static String get operatingSystemVersion => io.Platform.operatingSystemVersion;
  static Map<String, String> get environment => io.Platform.environment;
  static String get localeName => io.Platform.localeName;
  static String get localHostname => io.Platform.localHostname;
  static int get numberOfProcessors => io.Platform.numberOfProcessors;
  static String get pathSeparator => io.Platform.pathSeparator;
  static String get lineTerminator => io.Platform.lineTerminator;
  static String get executable => io.Platform.executable;
  static String get resolvedExecutable => io.Platform.resolvedExecutable;
  static List<String> get executableArguments => io.Platform.executableArguments;
  static Uri get script => io.Platform.script;
  static String? get packageConfig => io.Platform.packageConfig;
  static String get version => io.Platform.version;
  static bool get stdoutSupportsAnsi => io.stdout.supportsAnsiEscapes;
  static bool get stdinSupportsAnsi => io.stdin.supportsAnsiEscapes;
}

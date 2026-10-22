/// Web stand-in for dart:io's Platform: every OS check is false.
class Platform {
  Platform._();

  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isLinux => false;
  static bool get isFuchsia => false;
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => '';
  static Map<String, String> get environment => const {};
  static String get localeName => 'en_US';
  static String get localHostname => '';
  static int get numberOfProcessors => 1;
  static String get pathSeparator => '/';
  static String get lineTerminator => '\n';
  static String get executable => '';
  static String get resolvedExecutable => '';
  static List<String> get executableArguments => const [];
  static Uri get script => Uri.base;
  static String? get packageConfig => null;
  static String get version => '';
  static bool get stdoutSupportsAnsi => false;
  static bool get stdinSupportsAnsi => false;
}

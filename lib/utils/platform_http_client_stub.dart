import 'package:http/http.dart' as http;

/// Used when dart:io is unavailable (web). `http.Client()` resolves to the
/// browser's fetch/XHR-backed client; connect timeouts aren't controllable
/// there, so [connectTimeout] is ignored (callers' own response deadlines
/// still apply). Native platforms never reach this: they select
/// `platform_http_client_io.dart` through the conditional imports.
http.Client createPlatformClient({Duration connectTimeout = Duration.zero}) => http.Client();

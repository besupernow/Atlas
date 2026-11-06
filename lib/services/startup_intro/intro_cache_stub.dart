// Web: the browser's HTTP cache keeps the clip; nothing to manage here.

Future<String?> introCachedPath(String id) async => null;

Future<void> introDownload(String id, String url) async {}

Future<void> introPrune(Set<String> keepIds) async {}

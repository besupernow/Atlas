/// Non-web builds never run guest mode.
void guestLeaveToApp() {}

String? guestStoredSession(String code) => null;

void guestStoreSession(String code, String? json) {}

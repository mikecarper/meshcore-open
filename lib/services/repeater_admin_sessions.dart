import 'dart:typed_data';

import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';

/// Observed admin logins only. Never stores passwords or assumes that a saved
/// password means the node has authenticated this Companion.
class RepeaterAdminSessions {
  String _companionKey = '';
  int _generation = 0;
  final Set<String> _adminKeys = {};

  int get generation => _generation;

  void bindCompanion(String key) {
    if (key.isEmpty || key == _companionKey) return;
    _companionKey = key;
    _generation++;
    _adminKeys.clear();
  }

  void observeLogin(
    Uint8List frame,
    List<Contact> contacts,
    String companionKey,
  ) {
    if (companionKey.isEmpty || frame.length < 8) return;
    if (frame[0] != pushCodeLoginSuccess && frame[0] != pushCodeLoginFail) {
      return;
    }
    bindCompanion(companionKey);
    final matches = contacts.where((contact) {
      if (contact.publicKey.length != 32) return false;
      for (var i = 0; i < 6; i++) {
        if (contact.publicKey[i] != frame[i + 2]) return false;
      }
      return true;
    }).toList();
    // A truncated prefix cannot safely choose between colliding full keys.
    if (matches.length != 1) {
      for (final contact in matches) {
        _adminKeys.remove(contact.publicKeyHex.toLowerCase());
      }
      return;
    }
    final contact = matches.single;
    final key = contact.publicKeyHex.toLowerCase();
    if (frame[0] == pushCodeLoginSuccess &&
        frame[1] == 1 &&
        (contact.type == advTypeRepeater || contact.type == advTypeRoom)) {
      _adminKeys.add(key);
    } else {
      _adminKeys.remove(key);
    }
  }

  bool isAdmin(String companionKey, Contact contact) =>
      companionKey.isNotEmpty &&
      companionKey == _companionKey &&
      contact.publicKey.length == 32 &&
      (contact.type == advTypeRepeater || contact.type == advTypeRoom) &&
      contact.isActive &&
      _adminKeys.contains(contact.publicKeyHex.toLowerCase());

  List<Contact> repeaters(List<Contact> contacts, String companionKey) =>
      infrastructure(
        contacts,
        companionKey,
      ).where((c) => c.type == advTypeRepeater).toList();

  List<Contact> infrastructure(List<Contact> contacts, String companionKey) =>
      contacts
          .where(
            (c) =>
                isAdmin(companionKey, c) &&
                contacts
                        .where(
                          (other) =>
                              other.publicKey.length >= 6 &&
                              other.publicKeyHex.substring(0, 12) ==
                                  c.publicKeyHex.substring(0, 12),
                        )
                        .length ==
                    1,
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

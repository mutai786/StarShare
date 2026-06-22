import 'package:flutter/foundation.dart';

class AppState {
  /// Triggers UI refresh (home/history/etc.)
  static final ValueNotifier<int> updateNotifier = ValueNotifier<int>(0);

  /// This device (sender/receiver identity)
  static String? deviceIp;
  static String? deviceName;

  /// QR-selected target device (receiver IP)
  static String? selectedIp;
  static int selectedPort = 5000;

  /// Last successful connection
  static String? lastConnectedIp;
  static String? lastConnectedDevice;

  /// ---------------------------
  /// UI REFRESH TRIGGER
  /// ---------------------------
  static void notifyUpdate() {
    updateNotifier.value++;
  }

  /// ---------------------------
  /// CURRENT DEVICE (THIS PHONE)
  /// ---------------------------
  static void setCurrentDevice({
    required String ip,
    String? name,
  }) {
    deviceIp = ip;
    deviceName = name;
  }

  /// ---------------------------
  /// QR / TARGET DEVICE
  /// ---------------------------
  static void setSelectedDevice({
    required String ip,
    int port = 5000,
  }) {
    selectedIp = ip;
    selectedPort = port;
  }

  /// ---------------------------
  /// LAST CONNECTION
  /// ---------------------------
  static void setLastDevice({
    required String ip,
    String? deviceName,
  }) {
    lastConnectedIp = ip;
    lastConnectedDevice = deviceName;
  }

  /// Clear selected device (optional reset)
  static void clearSelectedDevice() {
    selectedIp = null;
    selectedPort = 5000;
  }
}
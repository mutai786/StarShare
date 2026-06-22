class DeviceQR {
  final String ip;
  final int port;

  DeviceQR({
    required this.ip,
    required this.port,
  });

  String toQR() => "$ip:$port";

  static DeviceQR fromQR(String data) {
    final parts = data.split(":");
    return DeviceQR(
      ip: parts[0],
      port: int.parse(parts[1]),
    );
  }
}
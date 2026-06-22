class Transfer {
  final int? id;
  final String fileName;
  final int fileSize;
  final String direction;
  final String deviceIp;
  final String timestamp;

  Transfer({
    this.id,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.deviceIp,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'fileName': fileName,
      'fileSize': fileSize,
      'direction': direction,
      'deviceIp': deviceIp,
      'timestamp': timestamp,
    };
  }
}
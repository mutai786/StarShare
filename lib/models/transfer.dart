class Transfer {
  final int? id;
  final String fileName;
  final int fileSize;
  final String direction;
  final String deviceIp;
  final String timestamp;

  /// Where the received file was saved. Null for sent files and for entries
  /// created before this field existed.
  final String? filePath;

  Transfer({
    this.id,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.deviceIp,
    required this.timestamp,
    this.filePath,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'fileName': fileName,
      'fileSize': fileSize,
      'direction': direction,
      'deviceIp': deviceIp,
      'timestamp': timestamp,
      'filePath': filePath,
    };
  }
}

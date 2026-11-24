const kIgnoreReasonTrash = "trash";

class IgnoredFile {
  final String? localID;
  final String? title;
  final String? deviceFolder;
  String reason;

  IgnoredFile(this.localID, this.title, this.deviceFolder, this.reason);
}

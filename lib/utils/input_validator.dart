class InputValidator {
  const InputValidator();

  /// Returns null if valid, otherwise returns an error message.
  String? validateSearch(String value) {
    if (value.trim().isEmpty) {
      return "Please enter a file name.";
    }
    return null;
  }
}
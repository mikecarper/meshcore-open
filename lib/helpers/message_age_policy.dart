class MessageAgePolicy {
  static bool isExpired(DateTime timestamp, int hours, {DateTime? now}) =>
      hours > 0 &&
      timestamp.isBefore(
        (now ?? DateTime.now()).subtract(Duration(hours: hours)),
      );

  static List<T> keep<T>(
    Iterable<T> messages,
    DateTime Function(T) timestamp,
    int hours, {
    DateTime? now,
  }) {
    if (hours <= 0) return messages.toList();
    final cutoff = (now ?? DateTime.now()).subtract(Duration(hours: hours));
    return messages
        .where((message) => !timestamp(message).isBefore(cutoff))
        .toList();
  }
}

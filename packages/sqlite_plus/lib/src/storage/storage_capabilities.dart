/// What a caller may assume about a byte store. Read these fields. Do not
/// infer durability from the class name or from a successful round trip.
final class StorageCapabilities {
  const StorageCapabilities({
    required this.canRead,
    required this.canWrite,
    required this.durabilityPromised,
    required this.placement,
  });

  final bool canRead;
  final bool canWrite;

  /// A completed `sync` survives power loss only when this is true.
  /// Browser placement keeps it false: the bytes may be visible to a later
  /// open in this process, and that is not a power-loss promise.
  final bool durabilityPromised;

  /// `memory` means the browser interface was absent and the bytes die with
  /// the backend. `browser` means a browser byte store accepted the image.
  final StoragePlacement placement;

  static const memory = StorageCapabilities(
      canRead: true,
      canWrite: true,
      durabilityPromised: false,
      placement: StoragePlacement.memory);

  static const browser = StorageCapabilities(
      canRead: true,
      canWrite: true,
      durabilityPromised: false,
      placement: StoragePlacement.browser);

  static const readOnly = StorageCapabilities(
      canRead: true,
      canWrite: false,
      durabilityPromised: false,
      placement: StoragePlacement.memory);
}

enum StoragePlacement { memory, browser }

/// Rejects a write the flags do not allow, including a browser store that
/// someone treats as power-loss safe.
void requireWritable(StorageCapabilities capabilities) {
  if (!capabilities.canRead || !capabilities.canWrite) {
    throw StateError('Storage capabilities do not allow writing');
  }
  if (capabilities.placement == StoragePlacement.browser &&
      capabilities.durabilityPromised) {
    throw StateError('Browser storage must not promise power-loss durability');
  }
}

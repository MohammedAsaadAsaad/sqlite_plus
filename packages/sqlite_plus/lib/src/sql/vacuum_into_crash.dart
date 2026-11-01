/// Thrown after a `VACUUM INTO` temporary file is flushed and before it is
/// renamed onto the destination. The destination path is unchanged.
final class VacuumIntoCrash implements Exception {
  const VacuumIntoCrash();

  @override
  String toString() =>
      'VACUUM INTO stopped before the output file was published';
}

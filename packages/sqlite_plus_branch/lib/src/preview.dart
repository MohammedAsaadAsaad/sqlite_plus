part of '../sqlite_plus_branch.dart';

/// A completed callback and its exact reviewed working image. No implicit merge.
final class BranchOperationPreview<R> {
  BranchOperationPreview._(this._branch, this.value, this.review);
  final SqliteBranch _branch;
  final R value;
  final BranchMergePreview review;
  bool _closed = false;
  List<BranchRowDiff> get changes => review.changes;
  List<BranchConflict> get conflicts => review.conflicts;

  /// Both source and working image must still match the review. The callback is
  /// never rerun. Existing committed receipts still make retries idempotent.
  Future<BranchMergeResult> merge(
      {Map<String, BranchResolution> resolutions = const {}}) {
    if (_closed) return Future.error(const BranchException('Preview closed'));
    return _branch.merge(preview: review, resolutions: resolutions);
  }

  Future<void> close() async {
    if (_closed) return;
    await _branch.close();
    _closed = true;
  }
}

extension BranchOperationPreviews on SqlitePlusBranches {
  /// Run application SQL against an isolated working engine. Finish/close any
  /// ORM context inside the callback, and never close or retain the draft engine.
  /// External side effects in the callback are the application's responsibility.
  Future<BranchOperationPreview<R>> preview<R>(
      FutureOr<R> Function(MutableSqliteDatabase draft) action,
      {String name = 'preview'}) async {
    final branch = await create(name: name);
    try {
      final value = await action(branch.database);
      final review = await branch.previewMerge();
      return BranchOperationPreview._(branch, value, review);
    } catch (error, stack) {
      try {
        await branch.close();
      } catch (cleanup) {
        Error.throwWithStackTrace(
            BranchException('Preview failed and cleanup failed',
                (operation: error, cleanup: cleanup)),
            stack);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }
}

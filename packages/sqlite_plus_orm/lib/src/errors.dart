part of '../sqlite_plus_orm.dart';

/// Base failure for mapping, codec, state, and migration errors.
class OrmException implements Exception {
  /// [message] is shown to the caller. [cause] is the underlying error, if any.
  const OrmException(this.message, [this.cause]);

  /// What failed.
  final String message;

  /// The error that caused this failure, or null.
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// The model metadata cannot describe the requested schema or entity.
class OrmMappingException extends OrmException {
  /// [message] names the mapping rule that failed.
  const OrmMappingException(super.message, [super.cause]);
}

/// A value could not be encoded or decoded for its column.
class OrmCodecException extends OrmException {
  /// [message] names the property. [cause] is the encode or decode error.
  const OrmCodecException(super.message, [super.cause]);
}

/// The context or entity is in a state that rejects this call.
class OrmStateException extends OrmException {
  /// [message] names the rejected operation.
  const OrmStateException(super.message, [super.cause]);
}

/// A version column did not match the stored row.
class OptimisticConcurrencyException extends OrmException {
  /// The save was aborted. No partial update is committed.
  const OptimisticConcurrencyException(super.message, [super.cause]);
}

/// The live schema does not match the model.
class MigrationRequiredException extends OrmException {
  /// Call [SchemaMigrator.plan] and apply a reviewed plan.
  const MigrationRequiredException(super.message, [super.cause]);
}

/// [SchemaMigrator.apply] was asked to run a plan that still needs approval.
class MigrationApprovalRequiredException extends OrmException {
  /// Pass [MigrationApproval.forPlan] for that exact plan.
  const MigrationApprovalRequiredException(super.message, [super.cause]);
}

/// The database schema changed after the plan was created.
class SchemaChangedException extends OrmException {
  /// Build a new plan. The previous approval does not apply.
  const SchemaChangedException(super.message, [super.cause]);
}

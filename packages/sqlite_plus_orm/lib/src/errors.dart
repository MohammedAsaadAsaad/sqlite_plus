part of '../sqlite_plus_orm.dart';

class OrmException implements Exception {
  const OrmException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => '$runtimeType: $message';
}

class OrmMappingException extends OrmException {
  const OrmMappingException(super.message, [super.cause]);
}

class OrmCodecException extends OrmException {
  const OrmCodecException(super.message, [super.cause]);
}

class OrmStateException extends OrmException {
  const OrmStateException(super.message, [super.cause]);
}

class OptimisticConcurrencyException extends OrmException {
  const OptimisticConcurrencyException(super.message, [super.cause]);
}

class MigrationRequiredException extends OrmException {
  const MigrationRequiredException(super.message, [super.cause]);
}

class MigrationApprovalRequiredException extends OrmException {
  const MigrationApprovalRequiredException(super.message, [super.cause]);
}

class SchemaChangedException extends OrmException {
  const SchemaChangedException(super.message, [super.cause]);
}

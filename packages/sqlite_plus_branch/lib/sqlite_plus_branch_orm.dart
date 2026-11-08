/// Optional ORM convenience; mappings and generated columns work unchanged.
library;

import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'sqlite_plus_branch.dart';
export 'sqlite_plus_branch.dart';

extension SqliteBranchOrm on SqliteBranch {
  /// Context.close releases this adapter, leaving the branch open. Finish/save
  /// and close the context before branch diff/checkpoint/merge operations.
  OrmConnection get ormConnection => MutableDatabaseConnection(database);
}

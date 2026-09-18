export {
  Connection,
  ConnectionOptions,
  PreparedStatement,
  QueryOptions,
  connect,
  parseConnectionOptions,
} from "./connection.js";
export type { QueryResult } from "./protocol.js";
export { ConnectionPool, PoolOptions } from "./pool.js";
export {
  DatabaseError,
  DataError,
  InterfaceError,
  IntegrityError,
  InternalError,
  NotSupportedError,
  OperationalError,
  ProgrammingError,
  RubyDBError,
  TimeoutError,
} from "./errors.js";

export const version = "0.1.0";

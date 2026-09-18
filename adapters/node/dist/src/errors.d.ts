export declare class RubyDBError extends Error {
    readonly code?: string;
    readonly details?: unknown;
    constructor(message: string, code?: string, details?: unknown);
}
export declare class InterfaceError extends RubyDBError {
}
export declare class DatabaseError extends RubyDBError {
}
export declare class DataError extends DatabaseError {
}
export declare class OperationalError extends DatabaseError {
}
export declare class IntegrityError extends DatabaseError {
}
export declare class InternalError extends DatabaseError {
}
export declare class ProgrammingError extends DatabaseError {
}
export declare class NotSupportedError extends DatabaseError {
}
export declare class TimeoutError extends OperationalError {
}
export declare function errorFor(message: string, code?: string, details?: unknown): DatabaseError;
//# sourceMappingURL=errors.d.ts.map
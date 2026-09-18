export class RubyDBError extends Error {
  readonly code?: string;
  readonly details?: unknown;

  constructor(message: string, code?: string, details?: unknown) {
    super(message);
    this.name = new.target.name;
    this.code = code;
    this.details = details;
  }
}

export class InterfaceError extends RubyDBError {}
export class DatabaseError extends RubyDBError {}
export class DataError extends DatabaseError {}
export class OperationalError extends DatabaseError {}
export class IntegrityError extends DatabaseError {}
export class InternalError extends DatabaseError {}
export class ProgrammingError extends DatabaseError {}
export class NotSupportedError extends DatabaseError {}

export class TimeoutError extends OperationalError {}

export function errorFor(message: string, code?: string, details?: unknown): DatabaseError {
  const value = message.toLowerCase();
  if (code === "timeout" || value.includes("timeout") || value.includes("timed out")) {
    return new TimeoutError(message, code, details);
  }
  if (code === "busy" || value.includes("connection") || value.includes("authentication")) {
    return new OperationalError(message, code, details);
  }
  if (value.includes("syntax") || value.includes("parse") || value.includes("statement not found")) {
    return new ProgrammingError(message, code, details);
  }
  if (value.includes("unique") || value.includes("constraint") || value.includes("foreign key") || value.includes("not null")) {
    return new IntegrityError(message, code, details);
  }
  return new DatabaseError(message, code, details);
}

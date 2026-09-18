import { Connection, ConnectionOptions, connect } from "./connection.js";
import { InterfaceError, OperationalError } from "./errors.js";

export interface PoolOptions {
  minSize?: number;
  maxSize?: number;
  acquireTimeout?: number;
}

type Waiter = { resolve: (connection: Connection) => void; reject: (error: Error) => void; timer?: NodeJS.Timeout };

export class ConnectionPool {
  private readonly idle: Connection[] = [];
  private readonly waiters: Waiter[] = [];
  private created = 0;
  private closed = false;

  constructor(
    private readonly target: string | ConnectionOptions = {},
    readonly options: PoolOptions = {},
  ) {
    const minSize = options.minSize ?? 0;
    const maxSize = options.maxSize ?? 10;
    if (!Number.isInteger(minSize) || !Number.isInteger(maxSize) || minSize < 0 || maxSize < 1 || minSize > maxSize) {
      throw new InterfaceError("pool sizes must satisfy 0 <= minSize <= maxSize");
    }
  }

  static async create(target: string | ConnectionOptions = {}, options: PoolOptions = {}): Promise<ConnectionPool> {
    const pool = new ConnectionPool(target, options);
    for (let index = 0; index < (options.minSize ?? 0); index += 1) {
      pool.idle.push(await pool.newConnection());
    }
    return pool;
  }

  get size(): number {
    return this.created;
  }

  get available(): number {
    return this.idle.length;
  }

  async acquire(timeout = this.options.acquireTimeout): Promise<Connection> {
    if (this.closed) throw new InterfaceError("RubyDB connection pool is closed");
    const available = this.idle.pop();
    if (available) return available;
    if (this.created < (this.options.maxSize ?? 10)) return this.newConnection();

    return new Promise<Connection>((resolve, reject) => {
      const waiter: Waiter = { resolve, reject };
      if (timeout !== undefined) {
        waiter.timer = setTimeout(() => {
          const index = this.waiters.indexOf(waiter);
          if (index >= 0) this.waiters.splice(index, 1);
          reject(new OperationalError(`Timed out waiting ${timeout} seconds for a RubyDB connection`, "pool_timeout"));
        }, Math.max(timeout * 1000, 1));
      }
      this.waiters.push(waiter);
    });
  }

  release(connection: Connection): void {
    if (this.closed || connection.isClosed) {
      this.created = Math.max(this.created - 1, 0);
      void connection.close();
      return;
    }
    const waiter = this.waiters.shift();
    if (waiter) {
      if (waiter.timer) clearTimeout(waiter.timer);
      waiter.resolve(connection);
    } else {
      this.idle.push(connection);
    }
  }

  async use<T>(operation: (connection: Connection) => Promise<T>, timeout?: number): Promise<T> {
    const connection = await this.acquire(timeout);
    try {
      return await operation(connection);
    } finally {
      this.release(connection);
    }
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    while (this.waiters.length) {
      const waiter = this.waiters.shift() as Waiter;
      if (waiter.timer) clearTimeout(waiter.timer);
      waiter.reject(new InterfaceError("RubyDB connection pool is closed"));
    }
    const connections = this.idle.splice(0);
    await Promise.all(connections.map((connection) => connection.close()));
    this.created = 0;
  }

  private async newConnection(): Promise<Connection> {
    this.created += 1;
    try {
      return await connect(this.target);
    } catch (error) {
      this.created -= 1;
      throw error;
    }
  }
}

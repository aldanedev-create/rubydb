import { Connection, ConnectionOptions } from "./connection.js";
export interface PoolOptions {
    minSize?: number;
    maxSize?: number;
    acquireTimeout?: number;
}
export declare class ConnectionPool {
    private readonly target;
    readonly options: PoolOptions;
    private readonly idle;
    private readonly waiters;
    private created;
    private closed;
    constructor(target?: string | ConnectionOptions, options?: PoolOptions);
    static create(target?: string | ConnectionOptions, options?: PoolOptions): Promise<ConnectionPool>;
    get size(): number;
    get available(): number;
    acquire(timeout?: number | undefined): Promise<Connection>;
    release(connection: Connection): void;
    use<T>(operation: (connection: Connection) => Promise<T>, timeout?: number): Promise<T>;
    close(): Promise<void>;
    private newConnection;
}
//# sourceMappingURL=pool.d.ts.map
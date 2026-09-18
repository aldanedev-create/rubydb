import * as tls from "node:tls";
import { QueryResult } from "./protocol.js";
export interface ConnectionOptions {
    host?: string;
    port?: number;
    username?: string;
    password?: string;
    database?: string;
    ssl?: boolean | tls.ConnectionOptions;
    timeout?: number;
    maxFrameSize?: number;
    autocommit?: boolean;
}
export interface QueryOptions {
    timeout?: number;
}
export declare class PreparedStatement {
    private readonly connection;
    readonly sql: string;
    readonly statementId: string;
    private closed;
    constructor(connection: Connection, sql: string, statementId: string);
    execute<Row = Record<string, any>>(params?: unknown[], options?: QueryOptions): Promise<QueryResult<Row>>;
    close(): Promise<void>;
}
export declare class Connection {
    readonly options: Required<Pick<ConnectionOptions, "host" | "port" | "username" | "password" | "database" | "timeout" | "maxFrameSize">> & ConnectionOptions;
    private socket;
    private buffer;
    private readonly messages;
    private readonly waiters;
    private closed;
    private transactionActive;
    private autocommit;
    constructor(options: Required<Pick<ConnectionOptions, "host" | "port" | "username" | "password" | "database" | "timeout" | "maxFrameSize">> & ConnectionOptions);
    get isClosed(): boolean;
    get isAutocommit(): boolean;
    set isAutocommit(value: boolean);
    connect(): Promise<this>;
    close(): Promise<void>;
    ping(): Promise<boolean>;
    begin(): Promise<void>;
    commit(): Promise<void>;
    rollback(): Promise<void>;
    query<Row = Record<string, any>>(sql: string, params?: unknown[], options?: QueryOptions): Promise<QueryResult<Row>>;
    prepare(sql: string): Promise<PreparedStatement>;
    executePrepared<Row = Record<string, any>>(statement: PreparedStatement, params?: unknown[], options?: QueryOptions): Promise<QueryResult<Row>>;
    closeStatement(statementId: string): Promise<void>;
    private handshake;
    private beginIfNeeded;
    private request;
    private cancel;
    private ensureOpen;
    private ensureSocket;
    private write;
    private readMessage;
    private onData;
    private failWaiters;
}
export declare function parseConnectionOptions(value: string | ConnectionOptions): ConnectionOptions;
export declare function connect(value?: string | ConnectionOptions): Promise<Connection>;
//# sourceMappingURL=connection.d.ts.map
import { readFileSync } from "node:fs";
import * as net from "node:net";
import * as tls from "node:tls";

import {
  DatabaseError,
  DataError,
  InterfaceError,
  OperationalError,
  TimeoutError,
  errorFor,
} from "./errors.js";
import { PROTOCOL_VERSION, QueryResult, RubyDBMessage, message } from "./protocol.js";

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

type Socket = net.Socket | tls.TLSSocket;
type Waiter = { resolve: (message: RubyDBMessage) => void; reject: (error: Error) => void; timer?: NodeJS.Timeout };

export class PreparedStatement {
  private closed = false;

  constructor(
    private readonly connection: Connection,
    readonly sql: string,
    readonly statementId: string,
  ) {}

  async execute<Row = Record<string, any>>(params: unknown[] = [], options: QueryOptions = {}): Promise<QueryResult<Row>> {
    if (this.closed) throw new InterfaceError("prepared statement is closed");
    return this.connection.executePrepared<Row>(this, params, options);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    await this.connection.closeStatement(this.statementId);
    this.closed = true;
  }
}

export class Connection {
  private socket: Socket | null = null;
  private buffer = "";
  private readonly messages: RubyDBMessage[] = [];
  private readonly waiters: Waiter[] = [];
  private closed = true;
  private transactionActive = false;
  private autocommit: boolean;

  constructor(readonly options: Required<Pick<ConnectionOptions, "host" | "port" | "username" | "password" | "database" | "timeout" | "maxFrameSize">> & ConnectionOptions) {
    this.autocommit = options.autocommit ?? false;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  get isAutocommit(): boolean {
    return this.autocommit;
  }

  set isAutocommit(value: boolean) {
    this.autocommit = Boolean(value);
  }

  async connect(): Promise<this> {
    if (!this.closed) return this;
    const sslOptions = this.options.ssl;
    const useTls = Boolean(sslOptions);
    const socket: Socket = useTls
      ? tls.connect({
          host: this.options.host,
          port: this.options.port,
          ...(sslOptions === true ? {} : sslOptions),
        })
      : net.createConnection({ host: this.options.host, port: this.options.port });

    this.socket = socket;
    socket.setNoDelay(true);
    socket.on("data", (chunk) => this.onData(chunk));
    socket.on("error", (error) => this.failWaiters(new OperationalError(`RubyDB socket error: ${error.message}`)));
    socket.on("close", () => {
      if (!this.closed) this.failWaiters(new OperationalError("RubyDB server closed the connection"));
      this.closed = true;
    });

    await new Promise<void>((resolve, reject) => {
      const event = useTls ? "secureConnect" : "connect";
      const onConnect = () => {
        socket.off("error", onError);
        resolve();
      };
      const onError = (error: Error) => {
        socket.off(event, onConnect);
        reject(new OperationalError(`RubyDB connection failed: ${error.message}`));
      };
      socket.once(event, onConnect);
      socket.once("error", onError);
    });

    this.closed = false;
    try {
      await this.handshake();
      return this;
    } catch (error) {
      await this.close();
      throw error;
    }
  }

  async close(): Promise<void> {
    const socket = this.socket;
    this.closed = true;
    this.socket = null;
    this.transactionActive = false;
    this.failWaiters(new InterfaceError("RubyDB connection is closed"));
    if (!socket) return;
    try {
      socket.end(`${JSON.stringify(message("terminate"))}\n`);
    } catch {
      // The socket is already closing; there is nothing else to release.
    }
    socket.destroy();
  }

  async ping(): Promise<boolean> {
    this.ensureOpen();
    await this.request("ping");
    return true;
  }

  async begin(): Promise<void> {
    this.ensureOpen();
    await this.request("begin");
    this.transactionActive = true;
  }

  async commit(): Promise<void> {
    this.ensureOpen();
    if (!this.transactionActive) return;
    await this.request("commit");
    this.transactionActive = false;
  }

  async rollback(): Promise<void> {
    this.ensureOpen();
    if (!this.transactionActive) return;
    await this.request("rollback");
    this.transactionActive = false;
  }

  async query<Row = Record<string, any>>(sql: string, params: unknown[] = [], options: QueryOptions = {}): Promise<QueryResult<Row>> {
    this.ensureOpen();
    await this.beginIfNeeded(sql);
    const result = await this.request("query", {
      sql,
      params: params.map(encodeValue),
      ...(options.timeout === undefined ? {} : { deadline_at: new Date(Date.now() + options.timeout * 1000).toISOString() }),
    }, options.timeout);
    return resultFromPayload<Row>(result.payload);
  }

  async prepare(sql: string): Promise<PreparedStatement> {
    this.ensureOpen();
    if (!sql.trim()) throw new InterfaceError("SQL must be a non-empty string");
    const result = await this.request("prepare", { sql });
    const statementId = result.payload.statement_id ?? result.payload.data?.statement_id;
    if (!statementId) throw new DatabaseError("RubyDB prepare response did not include statement_id");
    return new PreparedStatement(this, sql, String(statementId));
  }

  async executePrepared<Row = Record<string, any>>(statement: PreparedStatement, params: unknown[] = [], options: QueryOptions = {}): Promise<QueryResult<Row>> {
    this.ensureOpen();
    await this.beginIfNeeded(statement.sql);
    const result = await this.request("execute", {
      statement_id: statement.statementId,
      params: params.map(encodeValue),
      ...(options.timeout === undefined ? {} : { deadline_at: new Date(Date.now() + options.timeout * 1000).toISOString() }),
    }, options.timeout);
    return resultFromPayload<Row>(result.payload);
  }

  async closeStatement(statementId: string): Promise<void> {
    this.ensureOpen();
    await this.request("close", { statement_id: statementId });
  }

  private async handshake(): Promise<void> {
    let response = await this.request("handshake", {
      protocol_version: PROTOCOL_VERSION,
      client_name: "rubydb-node",
      client_version: "0.1.0",
      username: this.options.username,
      database: this.options.database,
    }, this.options.timeout, false);
    if (response.payload.success === false) throw errorFor(String(response.payload.error ?? "handshake failed"));

    response = await this.request("authentication_response", {
      username: this.options.username,
      password: this.options.password,
      database: this.options.database,
      auth_method: this.options.password ? "password" : "none",
    }, this.options.timeout, false);
    if (response.payload.success === false) throw errorFor(String(response.payload.error ?? "authentication failed"));

    response = await this.request("synchronize", {
      capabilities: {},
      compression: false,
      encryption: false,
      pipeline: false,
      batch_size: 100,
      timeout: Math.ceil(this.options.timeout),
      max_rows: 10000,
    }, this.options.timeout, false);
    if (response.payload.success === false) throw errorFor(String(response.payload.error ?? "protocol synchronization failed"));
  }

  private async beginIfNeeded(sql: string): Promise<void> {
    if (this.autocommit || this.transactionActive) return;
    const keyword = sql.trim().split(/\s+/, 1)[0]?.toLowerCase();
    if (!keyword || ["begin", "commit", "rollback"].includes(keyword)) return;
    await this.begin();
  }

  private async request(type: string, payload: Record<string, any> = {}, timeout = this.options.timeout, autoBegin = true): Promise<RubyDBMessage> {
    this.ensureSocket();
    const requestId = `msg_${Math.random().toString(36).slice(2)}${Date.now().toString(36)}`;
    const wait = this.readMessage(timeout);
    this.write(message(type, payload, requestId));
    try {
      const response = await wait;
      if (response.payload?.success === false) {
        throw errorFor(String(response.payload.error ?? "RubyDB request failed"), response.payload.code, response.payload);
      }
      return response;
    } catch (error) {
      if (error instanceof TimeoutError && type !== "cancel") {
        await this.cancel(requestId);
      }
      throw error;
    }
  }

  private async cancel(targetRequestId: string): Promise<void> {
    if (this.closed || !this.socket) return;
    try {
      const wait = this.readMessage(2000);
      this.write(message("cancel", { target_request_id: targetRequestId }));
      const deadline = Date.now() + 2000;
      while (Date.now() < deadline) {
        const response = await wait;
        if (response.payload?.request_id === targetRequestId || response.payload?.target_request_id === targetRequestId) return;
      }
    } catch {
      await this.close();
    }
  }

  private ensureOpen(): void {
    if (this.closed) throw new InterfaceError("RubyDB connection is closed");
  }

  private ensureSocket(): void {
    this.ensureOpen();
    if (!this.socket) throw new InterfaceError("RubyDB socket is not connected");
  }

  private write(value: RubyDBMessage): void {
    this.ensureSocket();
    const socket = this.socket;
    if (!socket) throw new InterfaceError("RubyDB socket is not connected");
    const frame = `${JSON.stringify(value)}\n`;
    if (Buffer.byteLength(frame, "utf8") > this.options.maxFrameSize) throw new DataError("RubyDB request exceeds maxFrameSize");
    socket.write(frame);
  }

  private readMessage(timeout: number): Promise<RubyDBMessage> {
    if (this.messages.length) return Promise.resolve(this.messages.shift() as RubyDBMessage);
    return new Promise<RubyDBMessage>((resolve, reject) => {
      const waiter: Waiter = { resolve, reject };
      waiter.timer = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(new TimeoutError(`RubyDB request timed out after ${timeout} seconds`, "timeout"));
      }, Math.max(timeout * 1000, 1));
      this.waiters.push(waiter);
    });
  }

  private onData(chunk: Buffer): void {
    this.buffer += chunk.toString("utf8");
    if (Buffer.byteLength(this.buffer, "utf8") > this.options.maxFrameSize) {
      this.failWaiters(new OperationalError("RubyDB response exceeds maxFrameSize"));
      void this.close();
      return;
    }
    let newline = this.buffer.indexOf("\n");
    while (newline >= 0) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      newline = this.buffer.indexOf("\n");
      if (!line.trim()) continue;
      try {
        const parsed = JSON.parse(line) as RubyDBMessage;
        if (!parsed || typeof parsed !== "object" || typeof parsed.type !== "string") throw new Error("invalid message");
        const waiter = this.waiters.shift();
        if (waiter) {
          if (waiter.timer) clearTimeout(waiter.timer);
          waiter.resolve(parsed);
        } else {
          this.messages.push(parsed);
        }
      } catch (error) {
        this.failWaiters(new OperationalError(`Invalid RubyDB response frame: ${String(error)}`));
        void this.close();
        return;
      }
    }
  }

  private failWaiters(error: Error): void {
    while (this.waiters.length) {
      const waiter = this.waiters.shift() as Waiter;
      if (waiter.timer) clearTimeout(waiter.timer);
      waiter.reject(error);
    }
  }
}

export function parseConnectionOptions(value: string | ConnectionOptions): ConnectionOptions {
  if (typeof value !== "string") return { ...value };
  let url: URL;
  try {
    url = new URL(value);
  } catch (error) {
    throw new InterfaceError(`Invalid RubyDB URL: ${String(error)}`);
  }
  if (url.protocol !== "rubydb:" && url.protocol !== "rubydbs:") throw new InterfaceError("RubyDB URL must use rubydb:// or rubydbs://");
  if (!url.hostname) throw new InterfaceError("RubyDB URL must include a host");
  const ssl = url.protocol === "rubydbs:";
  const options: ConnectionOptions = {
    host: url.hostname,
    port: Number(url.port || 7432),
    username: decodeURIComponent(url.username || "rubydb"),
    password: decodeURIComponent(url.password || ""),
    database: decodeURIComponent(url.pathname.replace(/^\//, "") || "rubydb"),
    ssl,
  };
  const timeout = url.searchParams.get("timeout");
  const maxFrameSize = url.searchParams.get("max_frame_size");
  if (timeout) options.timeout = Number(timeout);
  if (maxFrameSize) options.maxFrameSize = Number(maxFrameSize);
  if (url.searchParams.get("verify_peer") === "false") options.ssl = { rejectUnauthorized: false };
  const caFile = url.searchParams.get("ca_file");
  const certFile = url.searchParams.get("cert_file");
  const keyFile = url.searchParams.get("key_file");
  if (ssl && (caFile || certFile || keyFile)) {
    const tlsOptions: tls.ConnectionOptions = { rejectUnauthorized: true };
    if (caFile) tlsOptions.ca = readFileSync(caFile);
    if (certFile) tlsOptions.cert = readFileSync(certFile);
    if (keyFile) tlsOptions.key = readFileSync(keyFile);
    options.ssl = tlsOptions;
  }
  return options;
}

export async function connect(value: string | ConnectionOptions = {}): Promise<Connection> {
  const options = parseConnectionOptions(value);
  const connection = new Connection({
    host: options.host ?? "127.0.0.1",
    port: options.port ?? 7432,
    username: options.username ?? "rubydb",
    password: options.password ?? "",
    database: options.database ?? "rubydb",
    timeout: options.timeout ?? 30,
    maxFrameSize: options.maxFrameSize ?? 10 * 1024 * 1024,
    ...options,
  });
  return connection.connect();
}

function encodeValue(value: unknown): unknown {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value;
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return value.toString("utf8");
  if (Array.isArray(value)) return value.map(encodeValue);
  if (typeof value === "object") return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([key, item]) => [key, encodeValue(item)]));
  throw new DataError(`Unsupported RubyDB parameter type: ${typeof value}`);
}

function resultFromPayload<Row>(payload: Record<string, any>): QueryResult<Row> {
  const source = (payload.result ?? payload.data ?? payload) as Record<string, any>;
  const rows = Array.isArray(source.rows) ? source.rows as Row[] : [];
  return {
    ...source,
    columns: Array.isArray(source.columns) ? source.columns : [],
    rows,
    rowCount: Number(source.row_count ?? source.rowCount ?? rows.length),
    affectedRows: Number(source.affected_rows ?? source.affectedRows ?? rows.length),
    insertId: source.inserted_id ?? source.insertId ?? source.row_id ?? null,
  };
}

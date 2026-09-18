import { readFileSync } from "node:fs";
import * as net from "node:net";
import * as tls from "node:tls";
import { DatabaseError, DataError, InterfaceError, OperationalError, TimeoutError, errorFor, } from "./errors.js";
import { PROTOCOL_VERSION, message } from "./protocol.js";
export class PreparedStatement {
    connection;
    sql;
    statementId;
    closed = false;
    constructor(connection, sql, statementId) {
        this.connection = connection;
        this.sql = sql;
        this.statementId = statementId;
    }
    async execute(params = [], options = {}) {
        if (this.closed)
            throw new InterfaceError("prepared statement is closed");
        return this.connection.executePrepared(this, params, options);
    }
    async close() {
        if (this.closed)
            return;
        await this.connection.closeStatement(this.statementId);
        this.closed = true;
    }
}
export class Connection {
    options;
    socket = null;
    buffer = "";
    messages = [];
    waiters = [];
    closed = true;
    transactionActive = false;
    autocommit;
    constructor(options) {
        this.options = options;
        this.autocommit = options.autocommit ?? false;
    }
    get isClosed() {
        return this.closed;
    }
    get isAutocommit() {
        return this.autocommit;
    }
    set isAutocommit(value) {
        this.autocommit = Boolean(value);
    }
    async connect() {
        if (!this.closed)
            return this;
        const sslOptions = this.options.ssl;
        const useTls = Boolean(sslOptions);
        const socket = useTls
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
            if (!this.closed)
                this.failWaiters(new OperationalError("RubyDB server closed the connection"));
            this.closed = true;
        });
        await new Promise((resolve, reject) => {
            const event = useTls ? "secureConnect" : "connect";
            const onConnect = () => {
                socket.off("error", onError);
                resolve();
            };
            const onError = (error) => {
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
        }
        catch (error) {
            await this.close();
            throw error;
        }
    }
    async close() {
        const socket = this.socket;
        this.closed = true;
        this.socket = null;
        this.transactionActive = false;
        this.failWaiters(new InterfaceError("RubyDB connection is closed"));
        if (!socket)
            return;
        try {
            socket.end(`${JSON.stringify(message("terminate"))}\n`);
        }
        catch {
            // The socket is already closing; there is nothing else to release.
        }
        socket.destroy();
    }
    async ping() {
        this.ensureOpen();
        await this.request("ping");
        return true;
    }
    async begin() {
        this.ensureOpen();
        await this.request("begin");
        this.transactionActive = true;
    }
    async commit() {
        this.ensureOpen();
        if (!this.transactionActive)
            return;
        await this.request("commit");
        this.transactionActive = false;
    }
    async rollback() {
        this.ensureOpen();
        if (!this.transactionActive)
            return;
        await this.request("rollback");
        this.transactionActive = false;
    }
    async query(sql, params = [], options = {}) {
        this.ensureOpen();
        await this.beginIfNeeded(sql);
        const result = await this.request("query", {
            sql,
            params: params.map(encodeValue),
            ...(options.timeout === undefined ? {} : { deadline_at: new Date(Date.now() + options.timeout * 1000).toISOString() }),
        }, options.timeout);
        return resultFromPayload(result.payload);
    }
    async prepare(sql) {
        this.ensureOpen();
        if (!sql.trim())
            throw new InterfaceError("SQL must be a non-empty string");
        const result = await this.request("prepare", { sql });
        const statementId = result.payload.statement_id ?? result.payload.data?.statement_id;
        if (!statementId)
            throw new DatabaseError("RubyDB prepare response did not include statement_id");
        return new PreparedStatement(this, sql, String(statementId));
    }
    async executePrepared(statement, params = [], options = {}) {
        this.ensureOpen();
        await this.beginIfNeeded(statement.sql);
        const result = await this.request("execute", {
            statement_id: statement.statementId,
            params: params.map(encodeValue),
            ...(options.timeout === undefined ? {} : { deadline_at: new Date(Date.now() + options.timeout * 1000).toISOString() }),
        }, options.timeout);
        return resultFromPayload(result.payload);
    }
    async closeStatement(statementId) {
        this.ensureOpen();
        await this.request("close", { statement_id: statementId });
    }
    async handshake() {
        let response = await this.request("handshake", {
            protocol_version: PROTOCOL_VERSION,
            client_name: "rubydb-node",
            client_version: "0.1.0",
            username: this.options.username,
            database: this.options.database,
        }, this.options.timeout, false);
        if (response.payload.success === false)
            throw errorFor(String(response.payload.error ?? "handshake failed"));
        response = await this.request("authentication_response", {
            username: this.options.username,
            password: this.options.password,
            database: this.options.database,
            auth_method: this.options.password ? "password" : "none",
        }, this.options.timeout, false);
        if (response.payload.success === false)
            throw errorFor(String(response.payload.error ?? "authentication failed"));
        response = await this.request("synchronize", {
            capabilities: {},
            compression: false,
            encryption: false,
            pipeline: false,
            batch_size: 100,
            timeout: Math.ceil(this.options.timeout),
            max_rows: 10000,
        }, this.options.timeout, false);
        if (response.payload.success === false)
            throw errorFor(String(response.payload.error ?? "protocol synchronization failed"));
    }
    async beginIfNeeded(sql) {
        if (this.autocommit || this.transactionActive)
            return;
        const keyword = sql.trim().split(/\s+/, 1)[0]?.toLowerCase();
        if (!keyword || ["begin", "commit", "rollback"].includes(keyword))
            return;
        await this.begin();
    }
    async request(type, payload = {}, timeout = this.options.timeout, autoBegin = true) {
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
        }
        catch (error) {
            if (error instanceof TimeoutError && type !== "cancel") {
                await this.cancel(requestId);
            }
            throw error;
        }
    }
    async cancel(targetRequestId) {
        if (this.closed || !this.socket)
            return;
        try {
            const wait = this.readMessage(2000);
            this.write(message("cancel", { target_request_id: targetRequestId }));
            const deadline = Date.now() + 2000;
            while (Date.now() < deadline) {
                const response = await wait;
                if (response.payload?.request_id === targetRequestId || response.payload?.target_request_id === targetRequestId)
                    return;
            }
        }
        catch {
            await this.close();
        }
    }
    ensureOpen() {
        if (this.closed)
            throw new InterfaceError("RubyDB connection is closed");
    }
    ensureSocket() {
        this.ensureOpen();
        if (!this.socket)
            throw new InterfaceError("RubyDB socket is not connected");
    }
    write(value) {
        this.ensureSocket();
        const socket = this.socket;
        if (!socket)
            throw new InterfaceError("RubyDB socket is not connected");
        const frame = `${JSON.stringify(value)}\n`;
        if (Buffer.byteLength(frame, "utf8") > this.options.maxFrameSize)
            throw new DataError("RubyDB request exceeds maxFrameSize");
        socket.write(frame);
    }
    readMessage(timeout) {
        if (this.messages.length)
            return Promise.resolve(this.messages.shift());
        return new Promise((resolve, reject) => {
            const waiter = { resolve, reject };
            waiter.timer = setTimeout(() => {
                const index = this.waiters.indexOf(waiter);
                if (index >= 0)
                    this.waiters.splice(index, 1);
                reject(new TimeoutError(`RubyDB request timed out after ${timeout} seconds`, "timeout"));
            }, Math.max(timeout * 1000, 1));
            this.waiters.push(waiter);
        });
    }
    onData(chunk) {
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
            if (!line.trim())
                continue;
            try {
                const parsed = JSON.parse(line);
                if (!parsed || typeof parsed !== "object" || typeof parsed.type !== "string")
                    throw new Error("invalid message");
                const waiter = this.waiters.shift();
                if (waiter) {
                    if (waiter.timer)
                        clearTimeout(waiter.timer);
                    waiter.resolve(parsed);
                }
                else {
                    this.messages.push(parsed);
                }
            }
            catch (error) {
                this.failWaiters(new OperationalError(`Invalid RubyDB response frame: ${String(error)}`));
                void this.close();
                return;
            }
        }
    }
    failWaiters(error) {
        while (this.waiters.length) {
            const waiter = this.waiters.shift();
            if (waiter.timer)
                clearTimeout(waiter.timer);
            waiter.reject(error);
        }
    }
}
export function parseConnectionOptions(value) {
    if (typeof value !== "string")
        return { ...value };
    let url;
    try {
        url = new URL(value);
    }
    catch (error) {
        throw new InterfaceError(`Invalid RubyDB URL: ${String(error)}`);
    }
    if (url.protocol !== "rubydb:" && url.protocol !== "rubydbs:")
        throw new InterfaceError("RubyDB URL must use rubydb:// or rubydbs://");
    if (!url.hostname)
        throw new InterfaceError("RubyDB URL must include a host");
    const ssl = url.protocol === "rubydbs:";
    const options = {
        host: url.hostname,
        port: Number(url.port || 7432),
        username: decodeURIComponent(url.username || "rubydb"),
        password: decodeURIComponent(url.password || ""),
        database: decodeURIComponent(url.pathname.replace(/^\//, "") || "rubydb"),
        ssl,
    };
    const timeout = url.searchParams.get("timeout");
    const maxFrameSize = url.searchParams.get("max_frame_size");
    if (timeout)
        options.timeout = Number(timeout);
    if (maxFrameSize)
        options.maxFrameSize = Number(maxFrameSize);
    if (url.searchParams.get("verify_peer") === "false")
        options.ssl = { rejectUnauthorized: false };
    const caFile = url.searchParams.get("ca_file");
    const certFile = url.searchParams.get("cert_file");
    const keyFile = url.searchParams.get("key_file");
    if (ssl && (caFile || certFile || keyFile)) {
        const tlsOptions = { rejectUnauthorized: true };
        if (caFile)
            tlsOptions.ca = readFileSync(caFile);
        if (certFile)
            tlsOptions.cert = readFileSync(certFile);
        if (keyFile)
            tlsOptions.key = readFileSync(keyFile);
        options.ssl = tlsOptions;
    }
    return options;
}
export async function connect(value = {}) {
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
function encodeValue(value) {
    if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean")
        return value;
    if (value instanceof Date)
        return value.toISOString();
    if (typeof value === "bigint")
        return value.toString();
    if (Buffer.isBuffer(value))
        return value.toString("utf8");
    if (Array.isArray(value))
        return value.map(encodeValue);
    if (typeof value === "object")
        return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, encodeValue(item)]));
    throw new DataError(`Unsupported RubyDB parameter type: ${typeof value}`);
}
function resultFromPayload(payload) {
    const source = (payload.result ?? payload.data ?? payload);
    const rows = Array.isArray(source.rows) ? source.rows : [];
    return {
        ...source,
        columns: Array.isArray(source.columns) ? source.columns : [],
        rows,
        rowCount: Number(source.row_count ?? source.rowCount ?? rows.length),
        affectedRows: Number(source.affected_rows ?? source.affectedRows ?? rows.length),
        insertId: source.inserted_id ?? source.insertId ?? source.row_id ?? null,
    };
}
//# sourceMappingURL=connection.js.map
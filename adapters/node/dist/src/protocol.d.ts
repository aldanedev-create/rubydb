export declare const PROTOCOL_VERSION = 65536;
export interface RubyDBMessage {
    type: string;
    id: string;
    created_at: string;
    payload: Record<string, any>;
    compressed: boolean;
    encrypted: boolean;
    checksum: string | null;
}
export interface QueryResult<Row = Record<string, any>> {
    columns: Array<Record<string, any>>;
    rows: Row[];
    rowCount: number;
    affectedRows: number;
    insertId?: number | string | null;
    [key: string]: any;
}
export declare function message(type: string, payload?: Record<string, any>, id?: string): RubyDBMessage;
//# sourceMappingURL=protocol.d.ts.map
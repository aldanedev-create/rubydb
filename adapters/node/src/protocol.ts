export const PROTOCOL_VERSION = 0x010000;

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

export function message(type: string, payload: Record<string, any> = {}, id = `msg_${cryptoRandomId()}`): RubyDBMessage {
  return {
    type,
    id,
    created_at: new Date().toISOString(),
    payload,
    compressed: false,
    encrypted: false,
    checksum: null,
  };
}

function cryptoRandomId(): string {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}

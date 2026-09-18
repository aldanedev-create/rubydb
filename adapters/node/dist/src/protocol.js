export const PROTOCOL_VERSION = 0x010000;
export function message(type, payload = {}, id = `msg_${cryptoRandomId()}`) {
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
function cryptoRandomId() {
    return Math.random().toString(36).slice(2) + Date.now().toString(36);
}
//# sourceMappingURL=protocol.js.map
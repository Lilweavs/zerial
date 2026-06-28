pub const RxOrTx = enum {
    RX,
    TX,
};

pub const Record = struct {
    text: []const u8,
    time: i64,
    rxOrTx: RxOrTx,
};

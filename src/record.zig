pub const RxOrTx = enum {
    RX,
    TX,
};

text: []const u8,
time: i64,
rxOrTx: RxOrTx,

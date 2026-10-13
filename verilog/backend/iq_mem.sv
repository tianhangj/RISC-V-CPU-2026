module iq_mem #(
    parameter integer WAKE_WIDTH = 4,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_MEM_DEPTH = 4,
    parameter integer LQ_DEPTH = 4,
    parameter integer SQ_DEPTH = 8
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic disp_valid, disp_prepare,
    input logic [MEM_IQ_BITS-1:0] disp_uop,
    input logic disp_src1_ready, disp_src2_ready,
    input logic [WAKE_WIDTH-1:0] wake_valid,
    input logic [WAKE_WIDTH*PW-1:0] wake_pdst,
    output wire mem_iq_has_free,
    output logic cand_valid,
    output logic cand_src2_ready,
    output logic [MEM_IQ_BITS-1:0] cand_uop,
    input logic cand_take
);
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1;
    localparam integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1;
    localparam integer MIDW = (LIDW > SIDW) ? LIDW : SIDW;
    localparam integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1);
    localparam integer TAG_BITS = RW;
    localparam integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32;
    iq_core #(.WAKE_WIDTH(WAKE_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .DEPTH(IQ_MEM_DEPTH), .UOP_BITS(MEM_IQ_BITS), .SRC2_LSB(32), .MEM_QUEUE(1), .STORE_OP_LSB(32+2*PW+MIDW)) core (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .disp_valid, .disp_prepare, .disp_uop, .disp_src1_ready, .disp_src2_ready,
        .wake_valid, .wake_pdst, .has_free(mem_iq_has_free),
        .cand_valid(cand_valid), .cand_src2_ready(cand_src2_ready), .cand_uop(cand_uop),
        .cand_take(cand_take));

endmodule

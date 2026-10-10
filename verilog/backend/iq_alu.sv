module iq_alu #(
    parameter integer WAKE_WIDTH = 4,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_ALU_DEPTH = 7,
    parameter integer CHECKPOINT_DEPTH = 4
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic disp_valid, disp_prepare,
    input logic [ALU_IQ_BITS-1:0] disp_uop,
    input logic disp_src1_ready, disp_src2_ready,
    input logic [WAKE_WIDTH-1:0] wake_valid,
    input logic [WAKE_WIDTH*PW-1:0] wake_pdst,
    output logic [AIQ_CW-1:0] alu_iq_free,
    output logic cand_valid,
    output logic [ALU_IQ_BITS-1:0] cand_uop,
    input logic cand_take
);
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1;
    localparam integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1);
    localparam integer TAG_BITS = RW;
    localparam integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 64;
    iq_core #(.WAKE_WIDTH(WAKE_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .DEPTH(IQ_ALU_DEPTH), .UOP_BITS(ALU_IQ_BITS), .SRC2_LSB(64)) core (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .disp_valid, .disp_prepare, .disp_uop, .disp_src1_ready, .disp_src2_ready,
        .wake_valid, .wake_pdst, .free_count(alu_iq_free),
        .cand_valid(cand_valid), .cand_src2_ready(), .cand_uop(cand_uop),
        .cand_take(cand_take));

endmodule

module iq_mem #(
    parameter integer ISSUE_WIDTH = 2, DISPATCH_WIDTH = 2, WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32, PRF_SIZE = 64, IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8, SQ_DEPTH = 8,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_uop,
    input logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    output logic [MIQ_CW-1:0] mem_iq_free,
    output logic [ISSUE_WIDTH-1:0] cand_valid,
    output logic [ISSUE_WIDTH*MEM_IQ_BITS-1:0] cand_uop,
    input logic [ISSUE_WIDTH-1:0] cand_take
);
    iq_core #(.ISSUE_WIDTH(ISSUE_WIDTH), .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .WB_WIDTH(WB_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .DEPTH(IQ_MEM_DEPTH), .UOP_BITS(MEM_IQ_BITS), .SRC2_LSB(32),
        .RW(RW), .PW(PW), .CW(MIQ_CW)) core (.*,
        .free_count(mem_iq_free));
endmodule

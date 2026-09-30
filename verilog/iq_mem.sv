module iq_mem #(
    parameter integer DISPATCH_WIDTH = 2, WB_WIDTH = 2,
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
    output logic cand_valid,
    output logic [MEM_IQ_BITS-1:0] cand_uop,
    input logic cand_take
);
    logic iq_cand_valid, iq_cand_take;
    logic [MEM_IQ_BITS-1:0] iq_cand_uop;
    logic candidate_valid_q;
    logic [MEM_IQ_BITS-1:0] candidate_reg;
    wire [RW-1:0] candidate_age = candidate_reg[MEM_IQ_BITS-1 -: RW] - rob_head;
    wire [RW-1:0] iq_candidate_age = iq_cand_uop[MEM_IQ_BITS-1 -: RW] - rob_head;

    iq_core #(.ISSUE_WIDTH(1), .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .WB_WIDTH(WB_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .DEPTH(IQ_MEM_DEPTH), .UOP_BITS(MEM_IQ_BITS), .SRC2_LSB(32),
        .BYPASS_WAKE(1), .RW(RW), .PW(PW), .CW(MIQ_CW)) core (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .disp_valid, .disp_uop, .disp_src1_ready, .disp_src2_ready,
        .wake_valid, .wake_pdst, .free_count(mem_iq_free),
        .cand_valid(iq_cand_valid), .cand_uop(iq_cand_uop),
        .cand_take(iq_cand_take));

    assign cand_valid = candidate_valid_q &&
        (!squash_valid || candidate_age <= (squash_tag - rob_head));
    assign cand_uop = candidate_reg;
    assign iq_cand_take = (!candidate_valid_q || cand_take || !cand_valid) &&
        iq_cand_valid &&
        (!squash_valid || iq_candidate_age <= (squash_tag - rob_head));

    always_ff @(posedge clock) begin
        if (reset) begin
            candidate_valid_q <= 0;
        end else if (!candidate_valid_q || cand_take || !cand_valid) begin
            candidate_valid_q <= iq_cand_take;
            if (iq_cand_take) candidate_reg <= iq_cand_uop;
        end
    end
endmodule

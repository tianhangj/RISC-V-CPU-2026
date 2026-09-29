module iq_core #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer DEPTH = 16,
    parameter integer UOP_BITS = 95,
    parameter integer SRC2_LSB = 64,
    parameter integer RW = $clog2(ROB_DEPTH),
    parameter integer PW = $clog2(PRF_SIZE),
    parameter integer CW = $clog2(DEPTH + 1)
) (
    input logic clock, reset, squash_valid,
    input logic [RW-1:0] squash_tag, rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*UOP_BITS-1:0] disp_uop,
    input logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    output logic [CW-1:0] free_count,
    output logic [ISSUE_WIDTH-1:0] cand_valid,
    output logic [ISSUE_WIDTH*UOP_BITS-1:0] cand_uop,
    input logic [ISSUE_WIDTH-1:0] cand_take
);
    logic [DEPTH-1:0] valid_q, ready1_q, ready2_q;
    logic [UOP_BITS-1:0] entry [0:DEPTH-1];
    wire [DEPTH*UOP_BITS-1:0] entry_flat;
    for (genvar s = 0; s < DEPTH; s = s + 1) begin : g_flat_entry
        assign entry_flat[s*UOP_BITS +: UOP_BITS] = entry[s];
    end
    logic [DEPTH-1:0] candidate_used, allocated;
    integer cand_slot [0:ISSUE_WIDTH-1];
    integer alloc_slot [0:DISPATCH_WIDTH-1];
    integer choice, free_temp;
    logic [RW-1:0] best_age, age;
    logic [PW-1:0] ps1, ps2;
    logic w1, w2;
    always @(valid_q or ready1_q or ready2_q or rob_head or entry_flat or disp_valid) begin
        free_temp = 0;
        for (int s = 0; s < DEPTH; s = s + 1)
            if (!valid_q[s]) free_temp = free_temp + 1;
        free_count = free_temp;
        candidate_used = 0;
        cand_valid = 0;
        cand_uop = 0;
        for (int lane = 0; lane < ISSUE_WIDTH; lane = lane + 1) begin
            choice = -1;
            best_age = {RW{1'b1}};
            for (int s = 0; s < DEPTH; s = s + 1) begin
                age = entry[s][UOP_BITS-1 -: RW] - rob_head;
                if (valid_q[s] && ready1_q[s] && ready2_q[s] && !candidate_used[s] &&
                    (choice < 0 || age < best_age)) begin
                    choice = s;
                    best_age = age;
                end
            end
            cand_slot[lane] = choice;
            if (choice >= 0) begin
                cand_valid[lane] = 1;
                cand_uop[lane*UOP_BITS +: UOP_BITS] = entry[choice];
                candidate_used[choice] = 1;
            end
        end
        allocated = 0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            choice = -1;
            for (int s = 0; s < DEPTH; s = s + 1)
                if (choice < 0 && !valid_q[s] && !allocated[s]) choice = s;
            alloc_slot[lane] = choice;
            if (choice >= 0 && disp_valid[lane]) allocated[choice] = 1;
        end
    end
    always_ff @(posedge clock) begin
        if (reset) begin
            valid_q <= 0;
            ready1_q <= 0;
            ready2_q <= 0;
        end else begin
            for (int s = 0; s < DEPTH; s = s + 1) begin
                if (valid_q[s]) begin
                    if (squash_valid &&
                        ((entry[s][UOP_BITS-1 -: RW] - rob_head) > (squash_tag - rob_head)))
                        valid_q[s] <= 0;
                    ps1 = entry[s][SRC2_LSB+PW +: PW];
                    ps2 = entry[s][SRC2_LSB +: PW];
                    for (int w = 0; w < WB_WIDTH; w = w + 1) begin
                        if (wake_valid[w] && ps1 == wake_pdst[w*PW +: PW]) ready1_q[s] <= 1;
                        if (wake_valid[w] && ps2 == wake_pdst[w*PW +: PW]) ready2_q[s] <= 1;
                    end
                end
            end
            for (int lane = 0; lane < ISSUE_WIDTH; lane = lane + 1)
                if (cand_take[lane] && cand_slot[lane] >= 0)
                    valid_q[cand_slot[lane]] <= 0;
            for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
                if (disp_valid[lane] && alloc_slot[lane] >= 0 && !squash_valid) begin
                    entry[alloc_slot[lane]] <= disp_uop[lane*UOP_BITS +: UOP_BITS];
                    valid_q[alloc_slot[lane]] <= 1;
                    ps1 = disp_uop[lane*UOP_BITS+SRC2_LSB+PW +: PW];
                    ps2 = disp_uop[lane*UOP_BITS+SRC2_LSB +: PW];
                    w1 = disp_src1_ready[lane] || ps1 == 0;
                    w2 = disp_src2_ready[lane] || ps2 == 0;
                    for (int w = 0; w < WB_WIDTH; w = w + 1) begin
                        if (wake_valid[w] && ps1 == wake_pdst[w*PW +: PW]) w1 = 1;
                        if (wake_valid[w] && ps2 == wake_pdst[w*PW +: PW]) w2 = 1;
                    end
                    ready1_q[alloc_slot[lane]] <= w1;
                    ready2_q[alloc_slot[lane]] <= w2;
                end
            end
        end
    end
endmodule

module iq_alu #(
    parameter integer ISSUE_WIDTH = 2, DISPATCH_WIDTH = 2, WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32, PRF_SIZE = 64, IQ_ALU_DEPTH = 16,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 64
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] disp_uop,
    input logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    output logic [AIQ_CW-1:0] alu_iq_free,
    output logic [ISSUE_WIDTH-1:0] cand_valid,
    output logic [ISSUE_WIDTH*ALU_IQ_BITS-1:0] cand_uop,
    input logic [ISSUE_WIDTH-1:0] cand_take
);
    iq_core #(.ISSUE_WIDTH(ISSUE_WIDTH), .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .WB_WIDTH(WB_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .DEPTH(IQ_ALU_DEPTH), .UOP_BITS(ALU_IQ_BITS), .SRC2_LSB(64),
        .RW(RW), .PW(PW), .CW(AIQ_CW)) core (.*,
        .free_count(alu_iq_free));
endmodule

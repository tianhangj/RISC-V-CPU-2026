module branch_predictor #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer ISSUE_WIDTH = 2,
    parameter integer BP_ENABLE = 1,
    parameter integer BTB_ENTRIES = 64,
    parameter integer BHT_ENTRIES = 256,
    parameter integer BP_TRAIN_BITS = 66
) (
    input logic clock, reset,
    input logic [31:0] lookup_pc,
    output wire [DISPATCH_WIDTH-1:0] pred_taken,
    output wire [DISPATCH_WIDTH*32-1:0] pred_npc,
    // Events are packed in increasing ROB age by branch_ctrl.
    input logic [ISSUE_WIDTH-1:0] train_valid,
    input logic [ISSUE_WIDTH*BP_TRAIN_BITS-1:0] train_payload
);
    localparam integer BIW = $clog2(BTB_ENTRIES);
    localparam integer HIW = $clog2(BHT_ENTRIES);
    localparam integer BTAG = 30-BIW;
    logic btb_valid [0:BTB_ENTRIES-1];
    logic [BTAG-1:0] btb_tag [0:BTB_ENTRIES-1];
    logic [31:0] btb_target [0:BTB_ENTRIES-1];
    logic btb_conditional [0:BTB_ENTRIES-1];
    logic [1:0] bht [0:BHT_ENTRIES-1];

    for (genvar lane = 0; lane < DISPATCH_WIDTH; lane = lane+1) begin : g_lookup
        wire [31:0] pc = lookup_pc + 32'(lane*4);
        wire [BIW-1:0] bi = pc[2 +: BIW];
        wire [HIW-1:0] hi = pc[2 +: HIW];
        assign pred_taken[lane] = BP_ENABLE != 0 && pc[31:28] == 0 &&
            btb_valid[bi] && btb_tag[bi] == pc[31 -: BTAG] &&
            (!btb_conditional[bi] || bht[hi][1]);
        assign pred_npc[lane*32 +: 32] = pred_taken[lane] ? btb_target[bi] : pc+32'd4;
    end

    for (genvar entry = 0; entry < BTB_ENTRIES; entry = entry+1) begin : g_btb
        always_ff @(posedge clock) begin
            if (reset) btb_valid[entry] <= 0;
            else if (BP_ENABLE != 0)
                for (int lane = 0; lane < ISSUE_WIDTH; lane = lane+1)
                    if (train_valid[lane] &&
                        train_payload[lane*BP_TRAIN_BITS+36 +: BIW] == BIW'(entry)) begin
                        btb_valid[entry] <= 1;
                        btb_tag[entry] <= train_payload[lane*BP_TRAIN_BITS+65 -: BTAG];
                        btb_conditional[entry] <= train_payload[lane*BP_TRAIN_BITS+33];
                        btb_target[entry] <= train_payload[lane*BP_TRAIN_BITS +: 32];
                    end
        end
    end

    for (genvar entry = 0; entry < BHT_ENTRIES; entry = entry+1) begin : g_bht
        logic [1:0] next_counter;
        always_comb begin
            next_counter = bht[entry];
            for (int lane = 0; lane < ISSUE_WIDTH; lane = lane+1)
                if (BP_ENABLE != 0 && train_valid[lane] &&
                    train_payload[lane*BP_TRAIN_BITS+33] &&
                    train_payload[lane*BP_TRAIN_BITS+36 +: HIW] == HIW'(entry)) begin
                    if (train_payload[lane*BP_TRAIN_BITS+32]) begin
                        if (next_counter != 2'b11) next_counter = next_counter+2'd1;
                    end else if (next_counter != 2'b00) next_counter = next_counter-2'd1;
                end
        end
        always_ff @(posedge clock) begin
            if (reset) bht[entry] <= 2'b01;
            else bht[entry] <= next_counter;
        end
    end
endmodule

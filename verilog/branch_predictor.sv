module branch_predictor #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer ISSUE_WIDTH = 2,
    parameter integer BP_ENABLE = 1,
    parameter integer HISTORY_BITS = 0,
    parameter integer GLOBAL_HISTORY = 0,
    parameter integer BTB_RAM = 0,
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
    logic [1:0] bht [0:BHT_ENTRIES-1], bimodal [0:BHT_ENTRIES-1];
    reg [1:0] chooser [0:BTB_ENTRIES-1];
    localparam integer HW=(HISTORY_BITS>0)?HISTORY_BITS:1;
    reg [HW-1:0] history [0:BTB_ENTRIES-1];
    reg [HW-1:0] global_history;
    reg [HW-1:0] next_global_history;
    always @* begin
        next_global_history=global_history;
        for (integer lane=0; lane<ISSUE_WIDTH; lane=lane+1)
            if (train_valid[lane] && train_payload[lane*BP_TRAIN_BITS+33])
                next_global_history=(next_global_history<<1) | HW'(train_payload[lane*BP_TRAIN_BITS+32]);
    end
    always @(posedge clock) begin
        if (reset) global_history<=0;
        else global_history<=next_global_history;
    end
    wire [HIW-1:0] train_index [0:ISSUE_WIDTH-1];
    for (genvar lane=0; lane<ISSUE_WIDTH; lane=lane+1) begin : g_history_index
        wire [BIW-1:0] bi=train_payload[lane*BP_TRAIN_BITS+36 +: BIW];
        assign train_index[lane]=train_payload[lane*BP_TRAIN_BITS+36 +: HIW] ^
            (HISTORY_BITS>0?HIW'(GLOBAL_HISTORY!=0?global_history:history[bi]):{HIW{1'b0}});
    end
    localparam integer COUNTER_GROUPS=(BHT_ENTRIES+7)/8;
    localparam integer TRAIN_BITS=2+2*HIW;
    wire [ISSUE_WIDTH*COUNTER_GROUPS*TRAIN_BITS-1:0] counter_train;
    for (genvar lane=0; lane<ISSUE_WIDTH; lane=lane+1) begin : g_train_distribution
        (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(TRAIN_BITS), .BRANCHES(COUNTER_GROUPS)) distribute(
            {train_payload[lane*BP_TRAIN_BITS+36 +: HIW],train_index[lane],
             train_payload[lane*BP_TRAIN_BITS+32],
             (BP_ENABLE!=0 && train_valid[lane] && train_payload[lane*BP_TRAIN_BITS+33])},
            counter_train[lane*COUNTER_GROUPS*TRAIN_BITS +: COUNTER_GROUPS*TRAIN_BITS]);
    end
    for (genvar entry=0; entry<BTB_ENTRIES; entry=entry+1) begin : g_history
        always @(posedge clock) begin
            if (reset) begin history[entry]<=0; chooser[entry]<=1; end
            else if (HISTORY_BITS>0)
                for (integer lane=0; lane<ISSUE_WIDTH; lane=lane+1)
                    if (train_valid[lane] && train_payload[lane*BP_TRAIN_BITS+33] &&
                        train_payload[lane*BP_TRAIN_BITS+36 +: BIW]==BIW'(entry))
                        begin
                            if (GLOBAL_HISTORY==0)
                                history[entry]<=(history[entry]<<1) | HW'(train_payload[lane*BP_TRAIN_BITS+32]);
                            if (bht[train_index[lane]][1]!=bimodal[train_payload[lane*BP_TRAIN_BITS+36 +: HIW]][1]) begin
                                if (bht[train_index[lane]][1]==train_payload[lane*BP_TRAIN_BITS+32]) begin
                                    if (chooser[entry]!=3) chooser[entry]<=chooser[entry]+1'b1;
                                end else if (chooser[entry]!=0) chooser[entry]<=chooser[entry]-1'b1;
                            end
                        end
        end
    end

    for (genvar lane = 0; lane < DISPATCH_WIDTH; lane = lane+1) begin : g_lookup
        wire [31:0] pc, sequential_pc;
        if (lane == 0) begin : g_base_pc
            assign pc = lookup_pc;
        end else begin : g_offset_pc
            (* keep_hierarchy, keep *) pc_increment #(.WORDS(lane)) increment_lookup (
                .pc(lookup_pc), .next_pc(pc));
        end
        (* keep_hierarchy, keep *) pc_increment #(.WORDS(lane+1)) increment_next (
            .pc(lookup_pc), .next_pc(sequential_pc));
        wire [BIW-1:0] bi = pc[2 +: BIW];
        wire [HIW-1:0] hi = pc[2 +: HIW] ^
            (HISTORY_BITS>0?HIW'(GLOBAL_HISTORY!=0?global_history:history[bi]):{HIW{1'b0}});
        // Decode each index once; avoid binary mux address bits driving every
        // bit of the BTB tag/target arrays after memory lowering.
        wire [BTB_ENTRIES-1:0] hit;
        wire [31:0] target_word [0:BTB_ENTRIES-1];
        wire [BHT_ENTRIES-1:0] counter_taken, bimodal_taken;
        logic direction;
        logic [31:0] target;
        for (genvar entry = 0; entry < BHT_ENTRIES; entry = entry+1) begin : g_counter_read
            assign counter_taken[entry] = (hi == HIW'(entry)) && bht[entry][1];
            assign bimodal_taken[entry]=(pc[2 +: HIW]==HIW'(entry)) && bimodal[entry][1];
        end
        always_comb begin
            direction = HISTORY_BITS>0 && chooser[bi][1] ? |counter_taken : |bimodal_taken;
            target = 0;
            for (int entry = 0; entry < BTB_ENTRIES; entry = entry+1)
                target = target | target_word[entry];
        end
        for (genvar entry = 0; entry < BTB_ENTRIES; entry = entry+1) begin : g_target_read
            assign hit[entry] = (bi == BIW'(entry)) && btb_valid[entry] &&
                btb_tag[entry] == pc[31 -: BTAG] &&
                (!btb_conditional[entry] || direction);
            assign target_word[entry] = btb_target[entry] & {32{hit[entry]}};
        end
        assign pred_taken[lane] = BP_ENABLE != 0 && pc[31:28] == 0 && (|hit);
        assign pred_npc[lane*32 +: 32] = pred_taken[lane] ? target : sequential_pc;
    end

    // Independent always-read SRAM words preserve combinational lookup.
    // Forward the previous update while the written word's read output is
    // unavailable; no extra prediction latency or speculative state is added.
    reg [ISSUE_WIDTH-1:0] last_train_valid;
    reg [ISSUE_WIDTH*BP_TRAIN_BITS-1:0] last_train_payload;
    always @(posedge clock) begin
        if (reset) last_train_valid<=0;
        else last_train_valid<=train_valid;
        last_train_payload<=train_payload;
    end
    localparam integer BTB_WRITE_GROUPS=(BTB_ENTRIES+7)/8;
    wire [BTB_WRITE_GROUPS*(BTAG+33)-1:0] single_write_data;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(BTAG+33), .BRANCHES(BTB_WRITE_GROUPS))
        distribute_btb_write({train_payload[65 -: BTAG],train_payload[33],train_payload[31:0]},single_write_data);
    for (genvar entry = 0; entry < BTB_ENTRIES; entry = entry+1) begin : g_btb
        wire [BTAG+32:0] ram_data;
        reg [BTAG+32:0] write_data, read_data;
        reg write_entry;
        always @* begin
            write_entry=0; write_data=ISSUE_WIDTH==1?single_write_data[(entry/8)*(BTAG+33) +: BTAG+33]:0; read_data=ram_data;
            for (integer lane=0; lane<ISSUE_WIDTH; lane=lane+1) begin
                if (BP_ENABLE!=0 && train_valid[lane] &&
                    train_payload[lane*BP_TRAIN_BITS+36 +: BIW]==BIW'(entry)) begin
                    write_entry=1;
                    if (ISSUE_WIDTH!=1) write_data={train_payload[lane*BP_TRAIN_BITS+65 -: BTAG],
                        train_payload[lane*BP_TRAIN_BITS+33],
                        train_payload[lane*BP_TRAIN_BITS +: 32]};
                end
                if (last_train_valid[lane] &&
                    last_train_payload[lane*BP_TRAIN_BITS+36 +: BIW]==BIW'(entry))
                    read_data={last_train_payload[lane*BP_TRAIN_BITS+65 -: BTAG],
                        last_train_payload[lane*BP_TRAIN_BITS+33],
                        last_train_payload[lane*BP_TRAIN_BITS +: 32]};
            end
        end
        always @(posedge clock) begin
            if (reset) btb_valid[entry]<=0;
            else if (write_entry) btb_valid[entry]<=1;
        end
        if (BTB_RAM!=0) begin : g_ram
            sram_fakeram #(.DEPTH(1), .WIDTH(BTAG+33)) word (
                .clk(clock), .en(1'b1), .we(write_entry && !reset),
                .wmask(1'b1), .addr(1'b0), .wdata(write_data), .rdata(ram_data));
            always @* begin
                btb_tag[entry]=read_data[BTAG+32:33];
                btb_conditional[entry]=read_data[32];
                btb_target[entry]=read_data[31:0];
            end
        end else begin : g_flops
            assign ram_data=0;
            always @(posedge clock)
                if (!reset && write_entry) begin
                    btb_tag[entry]<=write_data[BTAG+32:33];
                    btb_conditional[entry]<=write_data[32];
                    btb_target[entry]<=write_data[31:0];
                end
        end
    end

    for (genvar entry = 0; entry < BHT_ENTRIES; entry = entry+1) begin : g_bht
        logic [1:0] next_counter, next_bimodal;
        always_comb begin
            next_counter = bht[entry]; next_bimodal=bimodal[entry];
            for (int lane=0; lane<ISSUE_WIDTH; lane=lane+1)
                if (counter_train[(lane*COUNTER_GROUPS+entry/8)*TRAIN_BITS] &&
                    counter_train[(lane*COUNTER_GROUPS+entry/8)*TRAIN_BITS+2+HIW +: HIW]==HIW'(entry)) begin
                    if (counter_train[(lane*COUNTER_GROUPS+entry/8)*TRAIN_BITS+1]) begin
                        if (next_bimodal!=3) next_bimodal=next_bimodal+1'b1;
                    end else if (next_bimodal!=0) next_bimodal=next_bimodal-1'b1;
                end
            for (int lane = 0; lane < ISSUE_WIDTH; lane = lane+1)
                if (counter_train[(lane*COUNTER_GROUPS+entry/8)*TRAIN_BITS] &&
                    counter_train[(lane*COUNTER_GROUPS+entry/8)*TRAIN_BITS+2 +: HIW]==HIW'(entry)) begin
                    if (counter_train[(lane*COUNTER_GROUPS+entry/8)*TRAIN_BITS+1]) begin
                        if (next_counter != 2'b11) next_counter = next_counter+2'd1;
                    end else if (next_counter != 2'b00) next_counter = next_counter-2'd1;
                end
        end
        always_ff @(posedge clock) begin
            if (reset) begin bht[entry] <= 2'b01; bimodal[entry]<=2'b01; end
            else begin bht[entry] <= next_counter; bimodal[entry]<=next_bimodal; end
        end
    end
endmodule

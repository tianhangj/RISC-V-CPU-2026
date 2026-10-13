module branch_predictor #(
    parameter integer BP_ENABLE = 1,
    parameter integer BTB_ENTRIES = 32,
    parameter integer BHT_ENTRIES = 256
) (
    input logic clock, reset,
    input logic [31:0] lookup_pc,
    output wire pred_taken,
    output wire [31:0] pred_npc,
    // Events are packed in increasing ROB age by branch_ctrl.
    input logic train_valid,
    input logic [BP_TRAIN_BITS-1:0] train_payload
);
    localparam integer BP_TRAIN_BITS = 66;
    localparam integer BIW = $clog2(BTB_ENTRIES);
    localparam integer HIW = $clog2(BHT_ENTRIES);
    localparam integer BTAG = 30-BIW;
    reg last_train_valid;
    reg [BP_TRAIN_BITS-1:0] last_train_payload;
    logic btb_valid [0:BTB_ENTRIES-1];
    logic [BTAG-1:0] btb_tag [0:BTB_ENTRIES-1];
    logic [31:0] btb_target [0:BTB_ENTRIES-1];
    logic btb_conditional [0:BTB_ENTRIES-1];
    logic [1:0] bht [0:BHT_ENTRIES-1], bimodal [0:BHT_ENTRIES-1];
    reg [1:0] chooser [0:BTB_ENTRIES-1];
    localparam integer HW=8;
    reg [HW-1:0] global_history;
    reg [HW-1:0] next_global_history;
    always @* begin
        next_global_history=global_history;
        if (train_valid && train_payload[33])
                next_global_history=(next_global_history<<1) | HW'(train_payload[32]);
    end
    always @(posedge clock) begin
        if (reset) global_history<=0;
        else global_history<=next_global_history;
    end
    wire [HIW-1:0] train_index;
    begin : g_history_index
        wire [BIW-1:0] bi=train_payload[36 +: BIW];
        assign train_index=train_payload[36 +: HIW] ^
            HIW'(global_history);
    end
    localparam integer COUNTER_GROUPS=(BHT_ENTRIES+7)/8;
    localparam integer TRAIN_BITS=2+2*HIW;
    wire [COUNTER_GROUPS*TRAIN_BITS-1:0] counter_train;
    begin : g_train_distribution
        (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(TRAIN_BITS), .BRANCHES(COUNTER_GROUPS)) distribute(
            {train_payload[36 +: HIW],train_index,
             train_payload[32],
             (BP_ENABLE!=0 && train_valid && train_payload[33])},
            counter_train[COUNTER_GROUPS*TRAIN_BITS-1:0]);
    end
    for (genvar entry=0; entry<BTB_ENTRIES; entry=entry+1) begin : g_history
        always @(posedge clock) begin
            if (reset) chooser[entry]<=1;
            else if (train_valid && train_payload[33] &&
                        train_payload[36 +: BIW]==BIW'(entry))
                        begin
                            if (bht[train_index][1]!=bimodal[train_payload[36 +: HIW]][1]) begin
                                if (bht[train_index][1]==train_payload[32]) begin
                                    if (chooser[entry]!=3) chooser[entry]<=chooser[entry]+1'b1;
                                end else if (chooser[entry]!=0) chooser[entry]<=chooser[entry]-1'b1;
                            end
                        end
        end
    end

    begin : g_lookup
        wire [31:0] pc, sequential_pc;
        begin : g_base_pc
            assign pc = lookup_pc;
        end
        (* keep_hierarchy, keep *) pc_increment #(.WORDS(1)) increment_next (
            .pc(lookup_pc), .next_pc(sequential_pc));
        wire [BIW-1:0] bi = pc[2 +: BIW];
        wire [HIW-1:0] hi = pc[2 +: HIW] ^
            HIW'(global_history);
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
            direction = chooser[bi][1] ? |counter_taken : |bimodal_taken;
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
        // SRAM's most recently written word is bypassed only at the selected
        // lookup. A same-index, different-tag update must suppress the old hit.
        wire last_selected=last_train_valid && last_train_payload[36 +: BIW]==bi;
        wire last_hit=last_train_payload[65:34]==pc &&
            (!last_train_payload[33] || direction);
        assign pred_taken = BP_ENABLE != 0 && pc[31:28] == 0 &&
            (last_selected?last_hit:(|hit));
        assign pred_npc[31:0] = pred_taken ?
            (last_selected?last_train_payload[31:0]:target):sequential_pc;
    end

    // Independent always-read SRAM words preserve combinational lookup.
    // Forward the previous update while the written word's read output is
    // unavailable; no extra prediction latency or speculative state is added.
    always @(posedge clock) begin
        if (reset) last_train_valid<=0;
        else last_train_valid<=train_valid;
        last_train_payload<=train_payload;
    end
    localparam integer BTB_WRITE_GROUPS=(BTB_ENTRIES+7)/8;
    wire [BTB_WRITE_GROUPS*(BTAG+33)-1:0] single_write_data;
    wire [BTB_WRITE_GROUPS*(BIW+2)-1:0] write_control;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(BIW+2), .BRANCHES(BTB_WRITE_GROUPS))
        distribute_btb_control({train_payload[36 +: BIW],reset,train_valid},write_control);
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(BTAG+33), .BRANCHES(BTB_WRITE_GROUPS))
        distribute_btb_write({train_payload[65 -: BTAG],train_payload[33],train_payload[31:0]},single_write_data);
    for (genvar entry = 0; entry < BTB_ENTRIES; entry = entry+1) begin : g_btb
        wire [BTAG+32:0] ram_data;
        wire [BTAG+32:0] write_data=single_write_data[(entry/8)*(BTAG+33) +: BTAG+33];
        wire [BIW+1:0] control=write_control[(entry/8)*(BIW+2) +: BIW+2];
        wire write_entry=BP_ENABLE!=0 && control[0] && control[BIW+1:2]==BIW'(entry);
        always @(posedge clock) begin
            if (control[1]) btb_valid[entry]<=0;
            else if (write_entry) btb_valid[entry]<=1;
        end
        begin : g_ram
            sram_fakeram #(.DEPTH(1), .WIDTH(BTAG+33)) word (
                .clk(clock), .en(1'b1), .we(write_entry && !control[1]),
                .wmask(1'b1), .addr(1'b0), .wdata(write_data), .rdata(ram_data));
            always @* begin
                btb_tag[entry]=ram_data[BTAG+32:33];
                btb_conditional[entry]=ram_data[32];
                btb_target[entry]=ram_data[31:0];
            end
        end
    end

    for (genvar entry = 0; entry < BHT_ENTRIES; entry = entry+1) begin : g_bht
        logic [1:0] next_counter, next_bimodal;
        always_comb begin
            next_counter = bht[entry]; next_bimodal=bimodal[entry];
            if (counter_train[(entry/8)*TRAIN_BITS] &&
                    counter_train[(entry/8)*TRAIN_BITS+2+HIW +: HIW]==HIW'(entry)) begin
                    if (counter_train[(entry/8)*TRAIN_BITS+1]) begin
                        if (next_bimodal!=3) next_bimodal=next_bimodal+1'b1;
                    end else if (next_bimodal!=0) next_bimodal=next_bimodal-1'b1;
                end
            if (counter_train[(entry/8)*TRAIN_BITS] &&
                    counter_train[(entry/8)*TRAIN_BITS+2 +: HIW]==HIW'(entry)) begin
                    if (counter_train[(entry/8)*TRAIN_BITS+1]) begin
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

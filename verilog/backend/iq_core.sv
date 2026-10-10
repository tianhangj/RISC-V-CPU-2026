module iq_core #(
    parameter integer WAKE_WIDTH = 4,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48,
    parameter integer DEPTH = 16,
    parameter integer UOP_BITS = 95,
    parameter integer SRC2_LSB = 64,
    parameter integer MEM_QUEUE = 0,
    parameter integer STORE_OP_LSB = SRC2_LSB+2*PW
) (
    input logic clock, reset, squash_valid,
    input logic [RW-1:0] squash_tag, rob_head,
    input logic disp_valid, disp_prepare,
    input logic [UOP_BITS-1:0] disp_uop,
    input logic disp_src1_ready, disp_src2_ready,
    input logic [WAKE_WIDTH-1:0] wake_valid,
    input logic [WAKE_WIDTH*PW-1:0] wake_pdst,
    output logic [CW-1:0] free_count,
    output logic cand_valid,
    output logic cand_src2_ready,
    output logic [UOP_BITS-1:0] cand_uop,
    input logic cand_take
);
    localparam integer RW = $clog2(ROB_DEPTH);
    localparam integer PW = $clog2(PRF_SIZE);
    localparam integer CW = $clog2(DEPTH + 1);
    logic [DEPTH-1:0] valid_q, ready1_q, ready2_q;
    logic [UOP_BITS-1:0] entry [0:DEPTH-1];
    wire [DEPTH*UOP_BITS-1:0] entry_flat;
    for (genvar s = 0; s < DEPTH; s = s + 1) begin : g_flat_entry
        assign entry_flat[s*UOP_BITS +: UOP_BITS] = entry[s];
    end
    // Record age when entries arrive. Ready selection no longer subtracts
    // ROB head and carries age values through a comparator tree.
    reg [DEPTH-1:0] older [0:DEPTH-1];
    wire [DEPTH*DEPTH-1:0] older_flat;
    for (genvar s=0; s<DEPTH; s=s+1) begin : g_flat_age
        assign older_flat[s*DEPTH +: DEPTH]=older[s];
    end
    generate begin : g_order
        always @(posedge clock) begin
            if (reset) begin
                for (integer s=0; s<DEPTH; s=s+1) older[s]<=0;
            end else if (!squash_valid) begin
                for (integer s=0; s<DEPTH; s=s+1)
                        if (disp_valid && alloc_select[s]) begin
                            for (integer t=0; t<DEPTH; t=t+1) begin
                                older[s][t]<=valid_q[t];
                                older[t][s]<=0;
                            end
                        end
            end
        end
    end endgenerate
    logic [DEPTH-1:0] alloc_select;
    logic [CW-1:0] free_rank [0:DEPTH-1];
    logic [DEPTH-1:0] cand_select;
    logic [DEPTH-1:0] ready_candidate, data_ready;
    localparam integer PAYLOAD_GROUPS = (UOP_BITS+15)/16;
    wire [DEPTH*PAYLOAD_GROUPS-1:0] candidate_mask;
    begin : g_candidate_fanout
        for (genvar slot = 0; slot < DEPTH; slot = slot+1) begin : g_slot
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(PAYLOAD_GROUPS)) distribute(
                cand_select[slot],
                candidate_mask[(slot)*PAYLOAD_GROUPS +: PAYLOAD_GROUPS]);
        end
    end
    integer alloc_slot;
    integer free_temp;
    logic [PW-1:0] ps1, ps2;
    logic [PW-1:0] select_ps1, select_ps2;
    logic select_ready1, select_ready2;
    logic w1, w2;
    always @(valid_q or ready1_q or ready2_q or rob_head or entry_flat or disp_prepare or
             wake_valid or wake_pdst or older_flat) begin
        for (int s = 0; s < DEPTH; s = s + 1) begin
            select_ps1 = entry[s][SRC2_LSB+PW +: PW];
            select_ps2 = entry[s][SRC2_LSB +: PW];
            select_ready1 = ready1_q[s];
            select_ready2 = ready2_q[s];
            begin
                for (int w = 0; w < WAKE_WIDTH; w = w + 1) begin
                    if (wake_valid[w] && select_ps1 == wake_pdst[w*PW +: PW])
                        select_ready1 = 1;
                    if (wake_valid[w] && select_ps2 == wake_pdst[w*PW +: PW])
                        select_ready2 = 1;
                end
            end
            data_ready[s]=select_ready2;
            ready_candidate[s] = valid_q[s] && select_ready1 &&
                (select_ready2 || (MEM_QUEUE!=0 && entry[s][STORE_OP_LSB +: 3]>=5));
        end
        free_temp = 0;
        for (int s = 0; s < DEPTH; s = s + 1)
            if (!valid_q[s]) free_temp = free_temp + 1;
        free_count = CW'(free_temp);
        cand_valid = 0; cand_src2_ready=0;
        begin
            cand_select = 0;
            begin
                cand_valid=|ready_candidate;
                for (int s=0; s<DEPTH; s=s+1) begin
                    cand_select[s]=ready_candidate[s] && !(|(older[s] & ready_candidate));
                    if (cand_select[s]) cand_src2_ready=data_ready[s];
                end
            end
        end
        // Prepare the first free slot before the dispatch handshake.
        for (int s = 0; s < DEPTH; s = s+1) begin
            free_rank[s] = 0;
            for (int older = 0; older < s; older = older+1)
                free_rank[s] = free_rank[s] + CW'(!valid_q[older]);
        end
        begin
            alloc_select = 0;
            alloc_slot = -1;
            for (int s = 0; s < DEPTH; s = s+1) begin
                alloc_select[s] = !valid_q[s] && free_rank[s] == 0;
                if (alloc_select[s]) alloc_slot = s;
            end
        end
    end
    always @(entry_flat or candidate_mask) begin
        cand_uop = 0;
        for (int slot = 0; slot < DEPTH; slot = slot+1)
                for (int bit_no = 0; bit_no < UOP_BITS; bit_no = bit_no+1)
                    cand_uop[bit_no] |= entry[slot][bit_no] &
                        candidate_mask[(slot)*PAYLOAD_GROUPS+bit_no/16];
    end
    for (genvar slot = 0; slot < DEPTH; slot = slot+1) begin : g_prepare_entry
        wire [PAYLOAD_GROUPS-1:0] payload_enable;
        begin : g_lane
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(PAYLOAD_GROUPS)) distribute(
                disp_prepare && alloc_select[slot],
                payload_enable[PAYLOAD_GROUPS-1:0]);
        end
        for (genvar bit_no = 0; bit_no < UOP_BITS; bit_no = bit_no+1) begin : g_payload_bit
            always_ff @(posedge clock)
                if (payload_enable[bit_no/16])
                        entry[slot][bit_no] <= disp_uop[bit_no];
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
                    for (int w = 0; w < WAKE_WIDTH; w = w + 1) begin
                        if (wake_valid[w] && ps1 == wake_pdst[w*PW +: PW]) ready1_q[s] <= 1;
                        if (wake_valid[w] && ps2 == wake_pdst[w*PW +: PW]) ready2_q[s] <= 1;
                    end
                end
            end
            for (int s = 0; s < DEPTH; s = s + 1)
                if (cand_take && cand_select[s]) valid_q[s] <= 0;
            begin
                if (disp_valid && alloc_slot >= 0 && !squash_valid) begin
                    valid_q[alloc_slot] <= 1;
                    ps1 = disp_uop[SRC2_LSB+PW +: PW];
                    ps2 = disp_uop[SRC2_LSB +: PW];
                    w1 = disp_src1_ready || ps1 == 0;
                    w2 = disp_src2_ready || ps2 == 0;
                    for (int w = 0; w < WAKE_WIDTH; w = w + 1) begin
                        if (wake_valid[w] && ps1 == wake_pdst[w*PW +: PW]) w1 = 1;
                        if (wake_valid[w] && ps2 == wake_pdst[w*PW +: PW]) w2 = 1;
                    end
                    ready1_q[alloc_slot] <= w1;
                    ready2_q[alloc_slot] <= w2;
                end
            end
        end
    end
endmodule

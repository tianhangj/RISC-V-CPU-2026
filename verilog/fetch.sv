module fetch #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer GEN_WIDTH = 16,
    parameter [31:0] RESET_PC = 32'h00000000,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer FETCH_BITS = 96,
    parameter integer FETCH_REDIRECT_BITS = 32 + GEN_WIDTH,
    parameter integer IC_REQ_BITS = GEN_WIDTH + FIDW + DCW + 32,
    parameter integer IC_RSP_BITS = GEN_WIDTH + FIDW + DCW + 32*DISPATCH_WIDTH
) (
    input logic clock, reset,
    input logic fetch_redirect_valid,
    input logic [FETCH_REDIRECT_BITS-1:0] fetch_redirect_payload,
    output wire [31:0] lookup_pc,
    input logic [DISPATCH_WIDTH-1:0] pred_taken,
    input logic [DISPATCH_WIDTH*32-1:0] pred_npc,
    output logic ic_req_valid,
    input logic ic_req_ready,
    output logic [IC_REQ_BITS-1:0] ic_req_payload,
    input logic ic_rsp_valid,
    input logic [IC_RSP_BITS-1:0] ic_rsp_payload,
    output logic fetch_valid,
    input logic fetch_ready,
    output logic [DCW-1:0] fetch_count,
    output logic [DISPATCH_WIDTH*FETCH_BITS-1:0] fetch_packet
);
    localparam integer QCW = $clog2(FETCH_QUEUE_DEPTH + 1);
    localparam integer OCW = $clog2(IFETCH_OUTSTANDING + 1);
    localparam integer LINE_WORDS = ICACHE_LINE_BYTES/4;
    localparam integer LINE_W = $clog2(LINE_WORDS);
    localparam integer CREDIT_W = $clog2(IFETCH_OUTSTANDING + DISPATCH_WIDTH + 1);
    logic [1:0] state [0:FETCH_QUEUE_DEPTH-1]; // free, offer, waiting, ready
    logic [31:0] slot_pc [0:FETCH_QUEUE_DEPTH-1];
    logic [31:0] slot_npc [0:FETCH_QUEUE_DEPTH-1];
    logic slot_taken [0:FETCH_QUEUE_DEPTH-1];
    logic [31:0] slot_inst [0:FETCH_QUEUE_DEPTH-1];
    logic [GEN_WIDTH-1:0] slot_gen [0:FETCH_QUEUE_DEPTH-1];
    logic [FIDW-1:0] head_q, tail_q;
    logic [QCW-1:0] count_q;
    logic [OCW-1:0] outstanding_q;
    logic [GEN_WIDTH-1:0] fetch_gen;
    logic [31:0] next_pc;
    logic offer_valid;
    logic [FIDW-1:0] offer_id;
    logic [DCW-1:0] offer_count;
    logic [31:0] offer_pc;
    logic out_valid;
    logic [DCW-1:0] out_count;
    logic [DISPATCH_WIDTH*FETCH_BITS-1:0] out_packet;
    logic [DCW-1:0] ready_count;
    logic [DISPATCH_WIDTH*FETCH_BITS-1:0] ready_packet;
    logic stop_ready;
    logic stop_create;
    logic [31:0] create_next_pc;
    logic [DCW-1:0] create_count;
    logic [CREDIT_W-1:0] credits_used;
    integer slot_index;
    wire [FETCH_BITS-1:0] read_packet [0:DISPATCH_WIDTH-1];
    wire [1:0] read_state [0:DISPATCH_WIDTH-1];
    wire read_taken [0:DISPATCH_WIDTH-1];
    wire [31:0] lane_pc [0:DISPATCH_WIDTH-1];
    wire [31:0] lane_next_pc [0:DISPATCH_WIDTH-1];
    localparam integer PREDICTION_BRANCHES = 2*FETCH_QUEUE_DEPTH+1;
    wire [DISPATCH_WIDTH*PREDICTION_BRANCHES-1:0] prediction_taken;
    for (genvar lane = 0; lane < DISPATCH_WIDTH; lane = lane+1) begin : g_pc_increment
        // Keep the prediction decision local to each sixteen-bit NPC group.
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(PREDICTION_BRANCHES))
            distribute_prediction(next_pc[31:28] == 0 && pred_taken[lane],
                prediction_taken[lane*PREDICTION_BRANCHES +: PREDICTION_BRANCHES]);
        if (lane == 0) begin : g_base_pc
            assign lane_pc[lane] = next_pc;
        end else begin : g_offset_pc
            (* keep_hierarchy, keep *) pc_increment #(.WORDS(lane)) increment_pc (
                .pc(next_pc), .next_pc(lane_pc[lane]));
        end
        (* keep_hierarchy, keep *) pc_increment #(.WORDS(lane+1)) increment_next (
            .pc(next_pc), .next_pc(lane_next_pc[lane]));
    end
    for (genvar lane = 0; lane < DISPATCH_WIDTH; lane = lane+1) begin : g_queue_read
        logic [FETCH_BITS-1:0] packet;
        logic [1:0] status;
        logic taken;
        always_comb begin
            packet = 0;
            status = 0;
            taken = 0;
            for (int slot = 0; slot < FETCH_QUEUE_DEPTH; slot = slot+1)
                if (slot == (int'(head_q)+lane) % FETCH_QUEUE_DEPTH) begin
                    packet = packet | {slot_pc[slot], slot_inst[slot], slot_npc[slot]};
                    status = status | state[slot];
                    taken = taken | slot_taken[slot];
                end
        end
        assign read_packet[lane] = packet;
        assign read_state[lane] = status;
        assign read_taken[lane] = taken;
    end
    wire [DCW-1:0] rsp_count = ic_rsp_payload[32*DISPATCH_WIDTH +: DCW];
    wire [FIDW-1:0] rsp_id = ic_rsp_payload[32*DISPATCH_WIDTH+DCW +: FIDW];
    wire [GEN_WIDTH-1:0] rsp_gen = ic_rsp_payload[32*DISPATCH_WIDTH+DCW+FIDW +: GEN_WIDTH];
    wire rsp_current = ic_rsp_valid && rsp_gen == fetch_gen;
    wire req_fire = ic_req_valid && ic_req_ready;
    wire out_fire = fetch_valid && fetch_ready;
    wire load_output = (!out_valid || out_fire) && ready_count != 0;
    localparam integer OUTPUT_GROUPS = (DISPATCH_WIDTH*FETCH_BITS+15)/16;
    wire [OUTPUT_GROUPS-1:0] output_enable;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(OUTPUT_GROUPS))
        distribute_output_enable(load_output, output_enable);

    assign ic_req_valid = offer_valid && !fetch_redirect_valid;
    assign ic_req_payload = {fetch_gen, offer_id, offer_count, offer_pc};
    assign fetch_valid = out_valid && !fetch_redirect_valid;
    assign fetch_count = out_count;
    assign fetch_packet = out_packet;
    assign lookup_pc = next_pc;

    always_comb begin
        credits_used = CREDIT_W'(outstanding_q) +
            (req_fire ? CREDIT_W'(offer_count) : CREDIT_W'(0)) -
            (rsp_current ? CREDIT_W'(rsp_count) : CREDIT_W'(0));
        create_count = 0;
        stop_create = 0;
        create_next_pc = next_pc;
        if (!offer_valid || req_fire) begin
            for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                if (!stop_create && count_q < QCW'(FETCH_QUEUE_DEPTH-lane) &&
                    (lane < LINE_WORDS &&
                     next_pc[2 +: LINE_W] <= LINE_W'(LINE_WORDS-1-lane)) &&
                    (next_pc[31:28] != 0 ||
                     (lane < IFETCH_OUTSTANDING &&
                      credits_used < CREDIT_W'(IFETCH_OUTSTANDING-lane)))) begin
                    create_count = create_count + 1'b1;
                    create_next_pc = lane_next_pc[lane];
                    if (prediction_taken[lane*PREDICTION_BRANCHES]) begin
                        create_next_pc = pred_npc[lane*32 +: 32];
                        stop_create = 1;
                    end
                end
        end
        // Output owns a copy of its packet; its source slots are already free.
        ready_count = 0;
        ready_packet = 0;
        stop_ready = 0;
        slot_index = 0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            // Count/valid describe the prefix; unused lanes need no masking.
            ready_packet[lane*FETCH_BITS +: FETCH_BITS] = read_packet[lane];
            slot_index = (int'(head_q) + lane) % FETCH_QUEUE_DEPTH;
            if (lane >= int'(count_q) || read_state[lane] != 2'd3)
                stop_ready = 1;
            if (!stop_ready) begin
                ready_count = ready_count + 1'b1;
                if (read_taken[lane]) stop_ready = 1;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            head_q <= 0;
            tail_q <= 0;
            count_q <= 0;
            outstanding_q <= 0;
            fetch_gen <= 0;
            next_pc <= RESET_PC;
            offer_valid <= 0;
            out_valid <= 0;

        end else if (fetch_redirect_valid) begin
            head_q <= 0;
            tail_q <= 0;
            count_q <= 0;
            outstanding_q <= 0;
            offer_valid <= 0;
            out_valid <= 0;
            next_pc <= fetch_redirect_payload[GEN_WIDTH +: 32];
            fetch_gen <= fetch_redirect_payload[GEN_WIDTH-1:0];

        end else begin
            outstanding_q <= OCW'(credits_used);
            if (req_fire) offer_valid <= 0;
            if (load_output) begin
                head_q <= head_q + FIDW'(ready_count);
            end
            if (!out_valid || out_fire) begin
                out_valid <= ready_count != 0;
                if (ready_count != 0) begin
                    out_count <= ready_count;
                end
            end
            if (create_count != 0) begin
                if (next_pc[31:28] == 0) begin
                    offer_valid <= 1;
                    offer_id <= tail_q;
                    offer_count <= DCW'(create_count);
                    offer_pc <= next_pc;
                end
                tail_q <= tail_q + FIDW'(create_count);
                next_pc <= create_next_pc;
            end
            if (load_output)
                count_q <= count_q + QCW'(create_count) - QCW'(ready_count);
            else
                count_q <= count_q + QCW'(create_count);
        end
    end
    // A local enable drives at most sixteen payload bits. Valid/count retain
    // the same acceptance edge and blocked packets keep their original data.
    for (genvar bit_no = 0; bit_no < DISPATCH_WIDTH*FETCH_BITS; bit_no = bit_no+1) begin : g_output_bit
        always_ff @(posedge clock)
            if (output_enable[bit_no/16]) out_packet[bit_no] <= ready_packet[bit_no];
    end
    // Static destinations share one write decode per slot instead of a
    // separate binary address mux for each stored bit.
    for (genvar slot = 0; slot < FETCH_QUEUE_DEPTH; slot = slot+1) begin : g_queue_write
        // Invalid slots may retain speculative data; only state needs reset
        // and redirect gating. Prepare free tail slots regardless of credits
        // or an older offer's handshake; create_count publishes their state.
        // This keeps recovery and cache readiness off the wide data enables.
        always_ff @(posedge clock) begin
            for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane+1) begin
                if (rsp_current && lane < rsp_count &&
                    slot == (int'(rsp_id)+lane) % FETCH_QUEUE_DEPTH &&
                    state[slot] == 2 && slot_gen[slot] == rsp_gen)
                    slot_inst[slot] <= ic_rsp_payload[lane*32 +: 32];
                if (count_q < QCW'(FETCH_QUEUE_DEPTH-lane) &&
                    slot == (int'(tail_q)+lane) % FETCH_QUEUE_DEPTH) begin
                    slot_pc[slot] <= lane_pc[lane];
                    for (int bit_no = 0; bit_no < 32; bit_no = bit_no+1)
                        slot_npc[slot][bit_no] <=
                            prediction_taken[lane*PREDICTION_BRANCHES+1+2*slot+bit_no/16] ?
                            pred_npc[lane*32+bit_no] : lane_next_pc[lane][bit_no];
                    slot_taken[slot] <= prediction_taken[lane*PREDICTION_BRANCHES+1+2*slot];
                    slot_gen[slot] <= fetch_gen;
                    if (next_pc[31:28] != 0) slot_inst[slot] <= 0;
                end
            end
            if (reset || fetch_redirect_valid) state[slot] <= 0;
            else begin
                for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane+1) begin
                    if (req_fire && lane < offer_count &&
                        slot == (int'(offer_id)+lane) % FETCH_QUEUE_DEPTH)
                        state[slot] <= 2;
                    if (rsp_current && lane < rsp_count &&
                        slot == (int'(rsp_id)+lane) % FETCH_QUEUE_DEPTH &&
                        state[slot] == 2 && slot_gen[slot] == rsp_gen)
                        state[slot] <= 3;
                    if (load_output && lane < ready_count &&
                        slot == (int'(head_q)+lane) % FETCH_QUEUE_DEPTH)
                        state[slot] <= 0;
                    if (lane < create_count &&
                        slot == (int'(tail_q)+lane) % FETCH_QUEUE_DEPTH)
                        state[slot] <= (next_pc[31:28] == 0) ? 2'd1 : 2'd3;
                end
            end
        end
    end
endmodule

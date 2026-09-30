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
    integer create_count, credits_used, slot_index;
    wire [FETCH_BITS-1:0] read_packet [0:DISPATCH_WIDTH-1];
    wire [1:0] read_state [0:DISPATCH_WIDTH-1];
    wire read_taken [0:DISPATCH_WIDTH-1];
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

    assign ic_req_valid = offer_valid && !fetch_redirect_valid;
    assign ic_req_payload = {fetch_gen, offer_id, offer_count, offer_pc};
    assign fetch_valid = out_valid && !fetch_redirect_valid;
    assign fetch_count = out_count;
    assign fetch_packet = out_packet;
    assign lookup_pc = next_pc;

    always_comb begin
        credits_used = int'(outstanding_q) + (req_fire ? int'(offer_count) : 0)
            - (rsp_current ? int'(rsp_count) : 0);
        create_count = 0;
        stop_create = 0;
        create_next_pc = next_pc;
        if (!offer_valid || req_fire) begin
            for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                if (!stop_create && lane < FETCH_QUEUE_DEPTH-int'(count_q) &&
                    lane < LINE_WORDS-int'((next_pc >> 2) & (LINE_WORDS-1)) &&
                    (next_pc[31:28] != 0 || lane < IFETCH_OUTSTANDING-credits_used)) begin
                    create_count = create_count + 1;
                    create_next_pc = next_pc + 32'((lane+1)*4);
                    if (next_pc[31:28] == 0 && pred_taken[lane]) begin
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
            slot_index = (int'(head_q) + lane) % FETCH_QUEUE_DEPTH;
            if (lane >= int'(count_q) || read_state[lane] != 2'd3)
                stop_ready = 1;
            if (!stop_ready) begin
                ready_packet[lane*FETCH_BITS +: FETCH_BITS] =
                    read_packet[lane];
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
                    out_packet <= ready_packet;
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
                count_q <= QCW'(int'(count_q) + create_count - int'(ready_count));
            else
                count_q <= QCW'(int'(count_q) + create_count);
        end
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
                if (lane < FETCH_QUEUE_DEPTH-int'(count_q) &&
                    slot == (int'(tail_q)+lane) % FETCH_QUEUE_DEPTH) begin
                    slot_pc[slot] <= next_pc + 32'(lane*4);
                    slot_npc[slot] <= (next_pc[31:28] == 0 && pred_taken[lane]) ?
                        pred_npc[lane*32 +: 32] : next_pc + 32'((lane+1)*4);
                    slot_taken[slot] <= next_pc[31:28] == 0 && pred_taken[lane];
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

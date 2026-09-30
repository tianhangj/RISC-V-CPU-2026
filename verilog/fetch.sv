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
    integer create_count, credits_used, slot_index;
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

    always_comb begin
        credits_used = int'(outstanding_q) + (req_fire ? int'(offer_count) : 0)
            - (rsp_current ? int'(rsp_count) : 0);
        create_count = 0;
        if (!fetch_redirect_valid && (!offer_valid || req_fire)) begin
            for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                if (lane < FETCH_QUEUE_DEPTH-int'(count_q) &&
                    lane < LINE_WORDS-int'((next_pc >> 2) & (LINE_WORDS-1)) &&
                    (next_pc[31:28] != 0 || lane < IFETCH_OUTSTANDING-credits_used))
                    create_count = create_count + 1;
        end
        // Output owns a copy of its packet; its source slots are already free.
        ready_count = 0;
        ready_packet = 0;
        stop_ready = 0;
        slot_index = 0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            slot_index = (int'(head_q) + lane) % FETCH_QUEUE_DEPTH;
            if (lane >= int'(count_q) || state[slot_index] != 2'd3)
                stop_ready = 1;
            if (!stop_ready) begin
                ready_packet[lane*FETCH_BITS +: FETCH_BITS] =
                    {slot_pc[slot_index], slot_inst[slot_index], slot_npc[slot_index]};
                ready_count = ready_count + 1'b1;
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
            for (int i = 0; i < FETCH_QUEUE_DEPTH; i = i + 1) state[i] <= 0;
        end else if (fetch_redirect_valid) begin
            head_q <= 0;
            tail_q <= 0;
            count_q <= 0;
            outstanding_q <= 0;
            offer_valid <= 0;
            out_valid <= 0;
            next_pc <= fetch_redirect_payload[GEN_WIDTH +: 32];
            fetch_gen <= fetch_redirect_payload[GEN_WIDTH-1:0];
            for (int i = 0; i < FETCH_QUEUE_DEPTH; i = i + 1) state[i] <= 0;
        end else begin
            outstanding_q <= OCW'(credits_used);
            if (req_fire) begin
                offer_valid <= 0;
                for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                    if (lane < offer_count)
                        state[(int'(offer_id)+lane) % FETCH_QUEUE_DEPTH] <= 2;
            end
            if (rsp_current) begin
                for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                    if (lane < rsp_count &&
                        state[(int'(rsp_id)+lane) % FETCH_QUEUE_DEPTH] == 2'd2 &&
                        slot_gen[(int'(rsp_id)+lane) % FETCH_QUEUE_DEPTH] == rsp_gen) begin
                        slot_inst[(int'(rsp_id)+lane) % FETCH_QUEUE_DEPTH] <= ic_rsp_payload[lane*32 +: 32];
                        state[(int'(rsp_id)+lane) % FETCH_QUEUE_DEPTH] <= 3;
                    end
            end
            if (load_output) begin
                for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                    if (lane < ready_count) state[(int'(head_q)+lane) % FETCH_QUEUE_DEPTH] <= 0;
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
                for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                    if (lane < create_count) begin
                        slot_pc[(int'(tail_q)+lane) % FETCH_QUEUE_DEPTH] <= next_pc + 32'(lane*4);
                        slot_npc[(int'(tail_q)+lane) % FETCH_QUEUE_DEPTH] <= next_pc + 32'((lane+1)*4);
                        slot_gen[(int'(tail_q)+lane) % FETCH_QUEUE_DEPTH] <= fetch_gen;
                        if (next_pc[31:28] == 0)
                            state[(int'(tail_q)+lane) % FETCH_QUEUE_DEPTH] <= 1;
                        else begin
                            slot_inst[(int'(tail_q)+lane) % FETCH_QUEUE_DEPTH] <= 0;
                            state[(int'(tail_q)+lane) % FETCH_QUEUE_DEPTH] <= 3;
                        end
                    end
                if (next_pc[31:28] == 0) begin
                    offer_valid <= 1;
                    offer_id <= tail_q;
                    offer_count <= DCW'(create_count);
                    offer_pc <= next_pc;
                end
                tail_q <= tail_q + FIDW'(create_count);
                next_pc <= next_pc + 32'(create_count*4);
            end
            if (load_output)
                count_q <= QCW'(int'(count_q) + create_count - int'(ready_count));
            else
                count_q <= QCW'(int'(count_q) + create_count);
        end
    end
endmodule

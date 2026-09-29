module fetch #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer GEN_WIDTH = 16,
    parameter [31:0] RESET_PC = 32'h00000000,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer FETCH_BITS = 96,
    parameter integer FETCH_REDIRECT_BITS = 32 + GEN_WIDTH,
    parameter integer IF_REQ_BITS = GEN_WIDTH + FIDW + 32,
    parameter integer IF_RSP_BITS = GEN_WIDTH + FIDW + 32
) (
    input logic clock, reset,
    input logic fetch_redirect_valid,
    input logic [FETCH_REDIRECT_BITS-1:0] fetch_redirect_payload,
    output logic if_req_valid,
    input logic if_req_ready,
    output logic [IF_REQ_BITS-1:0] if_req_payload,
    input logic if_rsp_valid,
    input logic [IF_RSP_BITS-1:0] if_rsp_payload,
    output logic fetch_valid,
    input logic fetch_ready,
    output logic [DCW-1:0] fetch_count,
    output logic [DISPATCH_WIDTH*FETCH_BITS-1:0] fetch_packet
);
    localparam integer QCW = $clog2(FETCH_QUEUE_DEPTH + 1);
    localparam integer OCW = $clog2(IFETCH_OUTSTANDING + 1);
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
    logic out_valid;
    logic [DCW-1:0] out_count;
    logic [DISPATCH_WIDTH*FETCH_BITS-1:0] out_packet;
    logic found_req;
    logic [FIDW-1:0] req_id;
    logic [DCW-1:0] ready_count;
    logic [DISPATCH_WIDTH*FETCH_BITS-1:0] ready_packet;
    logic stop_ready;
    wire [FIDW-1:0] rsp_id = if_rsp_payload[32 +: FIDW];
    wire [GEN_WIDTH-1:0] rsp_gen = if_rsp_payload[32+FIDW +: GEN_WIDTH];
    wire req_fire = if_req_valid && if_req_ready;
    wire out_fire = fetch_valid && fetch_ready;
    wire blocked_req = if_req_valid && !if_req_ready;
    wire create_slot = !fetch_redirect_valid && !blocked_req && count_q < FETCH_QUEUE_DEPTH;

    always_comb begin
        found_req = 0;
        req_id = 0;
        for (int offset = 0; offset < FETCH_QUEUE_DEPTH; offset = offset + 1)
            if (offset < count_q && !found_req && state[(head_q + offset) % FETCH_QUEUE_DEPTH] == 2'd1) begin
                found_req = 1;
                req_id = (head_q + offset) % FETCH_QUEUE_DEPTH;
            end
        if_req_valid = found_req && outstanding_q < IFETCH_OUTSTANDING && !fetch_redirect_valid;
        if_req_payload = {slot_gen[req_id], req_id, slot_pc[req_id]};
        ready_count = 0;
        ready_packet = 0;
        stop_ready = 0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            if (lane >= count_q || state[(head_q + lane) % FETCH_QUEUE_DEPTH] != 2'd3)
                stop_ready = 1;
            if (!stop_ready) begin
                ready_packet[lane*FETCH_BITS +: FETCH_BITS] =
                    {slot_pc[(head_q + lane) % FETCH_QUEUE_DEPTH],
                     slot_inst[(head_q + lane) % FETCH_QUEUE_DEPTH],
                     slot_npc[(head_q + lane) % FETCH_QUEUE_DEPTH]};
                ready_count = ready_count + 1'b1;
            end
        end
    end
    assign fetch_valid = out_valid && !fetch_redirect_valid;
    assign fetch_count = out_count;
    assign fetch_packet = out_packet;

    always_ff @(posedge clock) begin
        if (reset) begin
            head_q <= 0;
            tail_q <= 0;
            count_q <= 0;
            outstanding_q <= 0;
            fetch_gen <= 0;
            next_pc <= RESET_PC;
            out_valid <= 0;
            for (int i = 0; i < FETCH_QUEUE_DEPTH; i = i + 1) state[i] <= 0;
        end else begin
            case ({req_fire, if_rsp_valid})
                2'b10: outstanding_q <= outstanding_q + 1'b1;
                2'b01: outstanding_q <= outstanding_q - 1'b1;
                default: begin end
            endcase
            if (fetch_redirect_valid) begin
                head_q <= 0;
                tail_q <= 0;
                count_q <= 0;
                out_valid <= 0;
                next_pc <= fetch_redirect_payload[GEN_WIDTH +: 32];
                fetch_gen <= fetch_redirect_payload[GEN_WIDTH-1:0];
                for (int i = 0; i < FETCH_QUEUE_DEPTH; i = i + 1) state[i] <= 0;
            end else begin
                if (req_fire) state[req_id] <= 2;
                if (if_rsp_valid && state[rsp_id] == 2'd2 && slot_gen[rsp_id] == rsp_gen) begin
                    slot_inst[rsp_id] <= if_rsp_payload[31:0];
                    state[rsp_id] <= 3;
                end
                if (out_fire) begin
                    for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                        if (lane < out_count) state[(head_q + lane) % FETCH_QUEUE_DEPTH] <= 0;
                    head_q <= head_q + out_count;
                    out_valid <= 0;
                end else if (!out_valid && ready_count != 0) begin
                    out_valid <= 1;
                    out_count <= ready_count;
                    out_packet <= ready_packet;
                end
                if (create_slot) begin
                    slot_pc[tail_q] <= next_pc;
                    slot_npc[tail_q] <= next_pc + 32'd4;
                    slot_gen[tail_q] <= fetch_gen;
                    if (next_pc[31:28] == 0) begin
                        state[tail_q] <= 1;
                    end else begin
                        slot_inst[tail_q] <= 0;
                        state[tail_q] <= 3;
                    end
                    tail_q <= tail_q + 1'b1;
                    next_pc <= next_pc + 32'd4;
                end
                count_q <= count_q + create_slot - (out_fire ? out_count : 0);
            end
        end
    end
endmodule

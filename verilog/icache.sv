module icache #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer ICACHE_SIZE_BYTES = 4096,
    parameter integer ICACHE_WAYS = 2,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer GEN_WIDTH = 16,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer IF_ID_WIDTH = $clog2(ICACHE_LINE_BYTES/4),
    parameter integer IC_REQ_BITS = GEN_WIDTH + FIDW + DCW + 32,
    parameter integer IC_RSP_BITS = GEN_WIDTH + FIDW + DCW + 32*DISPATCH_WIDTH,
    parameter integer IF_REQ_BITS = GEN_WIDTH + IF_ID_WIDTH + 32,
    parameter integer IF_RSP_BITS = GEN_WIDTH + IF_ID_WIDTH + 32
) (
    input logic clock, reset,
    input logic fetch_redirect_valid,
    input logic ic_req_valid,
    output logic ic_req_ready,
    input logic [IC_REQ_BITS-1:0] ic_req_payload,
    output logic ic_rsp_valid,
    output logic [IC_RSP_BITS-1:0] ic_rsp_payload,
    output logic if_req_valid,
    input logic if_req_ready,
    output logic [IF_REQ_BITS-1:0] if_req_payload,
    input logic if_rsp_valid,
    input logic [IF_RSP_BITS-1:0] if_rsp_payload
);
    localparam integer SETS = ICACHE_SIZE_BYTES/(ICACHE_WAYS*ICACHE_LINE_BYTES);
    localparam integer LINE_BITS = ICACHE_LINE_BYTES*8;
    localparam integer LINE_WORDS = ICACHE_LINE_BYTES/4;
    localparam integer OFFSET_BITS = $clog2(ICACHE_LINE_BYTES);
    localparam integer SET_BITS = $clog2(SETS);
    localparam integer SET_WIDTH = (SETS > 1) ? SET_BITS : 1;
    localparam integer WAY_WIDTH = (ICACHE_WAYS > 1) ? $clog2(ICACHE_WAYS) : 1;
    localparam integer TAG_WIDTH = 32-OFFSET_BITS-SET_BITS;
    localparam integer FCW = $clog2(LINE_WORDS+1);
    logic [SETS*ICACHE_WAYS-1:0] line_valid;
    logic [TAG_WIDTH-1:0] tags [0:SETS*ICACHE_WAYS-1];
    logic [WAY_WIDTH-1:0] replace_way [0:SETS-1];
    wire [ICACHE_WAYS*LINE_BITS-1:0] ram_data;
    wire [31:0] req_addr = ic_req_payload[31:0];
    wire [DCW-1:0] req_count = ic_req_payload[32 +: DCW];
    wire [FIDW-1:0] req_id = ic_req_payload[32+DCW +: FIDW];
    wire [GEN_WIDTH-1:0] req_gen = ic_req_payload[32+DCW+FIDW +: GEN_WIDTH];
    wire [SET_WIDTH-1:0] req_set = SET_WIDTH'((req_addr >> OFFSET_BITS) & (SETS-1));
    wire [TAG_WIDTH-1:0] req_tag = TAG_WIDTH'(req_addr >> (OFFSET_BITS+SET_BITS));
    wire [IF_ID_WIDTH-1:0] req_word = req_addr[2 +: IF_ID_WIDTH];
    logic hit_found, invalid_found;
    logic [WAY_WIDTH-1:0] hit_way, victim_way;

    // A hit response occupies the SRAM read cycle following acceptance.
    logic hit_pending;
    logic [WAY_WIDTH-1:0] hit_way_q;
    logic [IF_ID_WIDTH-1:0] hit_word_q;
    logic [GEN_WIDTH-1:0] hit_gen_q;
    logic [FIDW-1:0] hit_id_q;
    logic [DCW-1:0] hit_count_q;

    // One physical refill, independent of its cancellable frontend waiter.
    logic fill_busy, fill_installed, waiter_valid;
    logic [31:0] fill_addr;
    logic [SET_WIDTH-1:0] fill_set;
    logic [WAY_WIDTH-1:0] fill_way;
    logic [GEN_WIDTH-1:0] fill_gen;
    logic [FCW-1:0] sent_count, received_count;
    logic [LINE_BITS-1:0] fill_data;
    logic [GEN_WIDTH-1:0] waiter_gen;
    logic [FIDW-1:0] waiter_id;
    logic [DCW-1:0] waiter_count;
    logic [IF_ID_WIDTH-1:0] waiter_word;
    logic [DISPATCH_WIDTH*32-1:0] rsp_insts;
    wire write_line = fill_busy && !fill_installed && received_count == FCW'(LINE_WORDS);
    wire same_fill = (req_addr >> OFFSET_BITS) == (fill_addr >> OFFSET_BITS);
    wire request_fire = ic_req_valid && ic_req_ready;
    wire hit_fire = request_fire && hit_found;
    wire fill_response = fill_busy && fill_installed && waiter_valid && !hit_pending;
    wire [IF_ID_WIDTH-1:0] return_word = if_rsp_payload[32 +: IF_ID_WIDTH];
    wire [GEN_WIDTH-1:0] return_gen = if_rsp_payload[32+IF_ID_WIDTH +: GEN_WIDTH];

    always_comb begin
        hit_found = 0;
        hit_way = 0;
        invalid_found = 0;
        victim_way = replace_way[req_set];
        for (int way = 0; way < ICACHE_WAYS; way = way + 1) begin
            if (!hit_found && line_valid[int'(req_set)*ICACHE_WAYS+way] &&
                tags[int'(req_set)*ICACHE_WAYS+way] == req_tag) begin
                hit_found = 1;
                hit_way = WAY_WIDTH'(way);
            end
            if (!invalid_found && !line_valid[int'(req_set)*ICACHE_WAYS+way]) begin
                invalid_found = 1;
                victim_way = WAY_WIDTH'(way);
            end
        end
        ic_req_ready = !reset && !fetch_redirect_valid && !write_line && req_addr[31:28] == 0 &&
            (hit_found || !fill_busy || (same_fill && !fill_installed && !waiter_valid));
        rsp_insts = 0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            if (hit_pending && lane < hit_count_q)
                rsp_insts[lane*32 +: 32] = ram_data[int'(hit_way_q)*LINE_BITS+(int'(hit_word_q)+lane)*32 +: 32];
            else if (fill_response && lane < waiter_count)
                rsp_insts[lane*32 +: 32] = fill_data[(int'(waiter_word)+lane)*32 +: 32];
        end
        ic_rsp_valid = !reset && !fetch_redirect_valid && (hit_pending || fill_response);
        if (hit_pending)
            ic_rsp_payload = {hit_gen_q, hit_id_q, hit_count_q, rsp_insts};
        else
            ic_rsp_payload = {waiter_gen, waiter_id, waiter_count, rsp_insts};
    end
    assign if_req_valid = !reset && fill_busy && sent_count < FCW'(LINE_WORDS);
    assign if_req_payload = {fill_gen, sent_count[IF_ID_WIDTH-1:0], fill_addr + (32'(sent_count) << 2)};

    generate
        for (genvar way = 0; way < ICACHE_WAYS; way = way + 1) begin : data_way
            wire writing = write_line && fill_way == WAY_WIDTH'(way);
            sram_fakeram #(.DEPTH(SETS), .WIDTH(LINE_BITS)) data_ram (
                .clk(clock), .en(writing || (hit_fire && hit_way == WAY_WIDTH'(way))),
                .we(writing), .wmask(1'b1), .addr(writing ? fill_set : req_set),
                .wdata(fill_data), .rdata(ram_data[way*LINE_BITS +: LINE_BITS])
            );
        end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset) begin
            line_valid <= 0;
            hit_pending <= 0;
            fill_busy <= 0;
            fill_installed <= 0;
            waiter_valid <= 0;
            sent_count <= 0;
            received_count <= 0;
            for (int set_id = 0; set_id < SETS; set_id = set_id + 1) replace_way[set_id] <= 0;
        end else begin
            hit_pending <= hit_fire;
            if (hit_fire) begin
                hit_way_q <= hit_way;
                hit_word_q <= req_word;
                hit_gen_q <= req_gen;
                hit_id_q <= req_id;
                hit_count_q <= req_count;
            end
            if (request_fire && !hit_found) begin
                waiter_valid <= 1;
                waiter_gen <= req_gen;
                waiter_id <= req_id;
                waiter_count <= req_count;
                waiter_word <= req_word;
                if (!fill_busy) begin
                    fill_busy <= 1;
                    fill_installed <= 0;
                    fill_addr <= (req_addr >> OFFSET_BITS) << OFFSET_BITS;
                    fill_set <= req_set;
                    fill_way <= victim_way;
                    fill_gen <= req_gen;
                    sent_count <= 0;
                    received_count <= 0;
                    line_valid[int'(req_set)*ICACHE_WAYS+int'(victim_way)] <= 0;
                end
            end
            if (if_req_valid && if_req_ready) sent_count <= sent_count + 1'b1;
            if (if_rsp_valid && fill_busy && !fill_installed && return_gen == fill_gen) begin
                fill_data[int'(return_word)*32 +: 32] <= if_rsp_payload[31:0];
                received_count <= received_count + 1'b1;
            end
            if (write_line) begin
                fill_installed <= 1;
                tags[int'(fill_set)*ICACHE_WAYS+int'(fill_way)] <= TAG_WIDTH'(fill_addr >> (OFFSET_BITS+SET_BITS));
                line_valid[int'(fill_set)*ICACHE_WAYS+int'(fill_way)] <= 1;
                replace_way[fill_set] <= (fill_way == WAY_WIDTH'(ICACHE_WAYS-1)) ? 0 : fill_way + 1'b1;
            end
            if (fill_busy && fill_installed && (!waiter_valid || !hit_pending)) begin
                fill_busy <= 0;
                waiter_valid <= 0;
            end
            if (fetch_redirect_valid) begin
                hit_pending <= 0;
                waiter_valid <= 0;
            end
        end
    end
endmodule

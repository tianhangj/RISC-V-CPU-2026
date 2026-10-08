// Blocking, set-associative write-back cache. Load hits accept one word per cycle;
// a miss transfers a complete line through the pipelined AXI bridge.
module dcache #(
    parameter integer SIZE_BYTES = 4096,
    parameter integer WAYS = 2,
    parameter integer LINE_BYTES = 32,
    parameter integer LQ_DEPTH = 4,
    parameter integer GEN_WIDTH = 16,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer WORDS = LINE_BYTES / 4,
    parameter integer WORD_W = (WORDS > 1) ? $clog2(WORDS) : 1,
    parameter integer LD_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer MEM_LD_BITS = GEN_WIDTH + WORD_W + 32
) (
    input wire clock, reset,
    input wire ld_req_valid,
    output wire ld_req_ready,
    input wire [LD_BITS-1:0] ld_req_payload,
    output wire ld_rsp_valid,
    output wire [LD_BITS-1:0] ld_rsp_payload,
    input wire st_req_valid,
    output wire st_req_ready,
    input wire [67:0] st_req_payload,
    output wire st_rsp_valid,
    output wire mem_ld_req_valid,
    input wire mem_ld_req_ready,
    output wire [MEM_LD_BITS-1:0] mem_ld_req_payload,
    input wire mem_ld_rsp_valid,
    input wire [MEM_LD_BITS-1:0] mem_ld_rsp_payload,
    output wire mem_st_req_valid,
    input wire mem_st_req_ready,
    output wire [67:0] mem_st_req_payload,
    input wire mem_st_rsp_valid
);
    localparam integer SETS = SIZE_BYTES / (WAYS * LINE_BYTES);
    localparam integer LINES = SETS * WAYS;
    localparam integer LINE_W = (LINES > 1) ? $clog2(LINES) : 1;
    localparam integer WAY_W = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam integer SET_W = (SETS > 1) ? $clog2(SETS) : 1;
    localparam integer OFFSET_W = $clog2(LINE_BYTES);
    localparam integer INDEX_BITS = $clog2(SETS);
    localparam integer TAG_W = 32 - OFFSET_W - INDEX_BITS;
    localparam integer LINE_BITS = LINE_BYTES * 8;
    localparam integer COUNT_W = $clog2(WORDS + 1);
    localparam [3:0] IDLE = 0, VICTIM = 1, WRITEBACK = 2,
        WRITE_WAIT = 3, REFILL = 4, INSTALL = 5, FLUSH_SCAN = 6,
        IO_SEND = 7, IO_WAIT = 8, PROBE = 9;
    reg [3:0] state;
    // Metadata is flattened as way*SETS+set, including during MMIO drain.
    reg [LINES-1:0] valid, dirty;
    reg [WAY_W-1:0] replace_way [0:SETS-1];
    reg [31:0] request_addr, request_data;
    reg [3:0] request_mask;
    reg [GEN_WIDTH+LIDW-1:0] request_identity;
    reg request_store, flushing;
    reg [SET_W-1:0] victim_set;
    reg [WAY_W-1:0] victim_way;
    reg [TAG_W-1:0] victim_tag;
    reg [LINE_BITS-1:0] victim_data;
    reg [COUNT_W-1:0] sent_count, received_count;
    reg miss_pending, store_pending;
    reg [LD_BITS-1:0] miss_response;

    wire [31:0] lookup_addr = st_req_valid ? st_req_payload[67:36] : ld_req_payload[31:0];
    wire [SET_W-1:0] lookup_set = SET_W'((lookup_addr >> OFFSET_W) & (SETS-1));
    wire [SET_W-1:0] request_set = SET_W'((request_addr >> OFFSET_W) & (SETS-1));
    wire [WORD_W-1:0] request_word = WORD_W'((request_addr >> 2) & (WORDS-1));
    wire [WORD_W-1:0] response_word = mem_ld_rsp_payload[32 +: WORD_W];
    wire [WORD_W-1:0] refill_index = request_word + WORD_W'(sent_count);
    // Read tag and data together at acceptance. PROBE publishes a hit in
    // the following cycle and can accept the next load at the same edge.
    wire [WAYS*TAG_W-1:0] tag_rdata;
    wire [WAYS*LINE_BITS-1:0] way_rdata;
    reg lookup_hit, invalid_found;
    reg [WAY_W-1:0] hit_way, replacement_way;
    always @* begin
        lookup_hit = 0;
        hit_way = 0;
        invalid_found = 0;
        replacement_way = replace_way[request_set];
        for (integer way = 0; way < WAYS; way = way+1) begin
            if (!lookup_hit && valid[way*SETS+request_set] &&
                tag_rdata[way*TAG_W +: TAG_W] == request_addr[31 -: TAG_W]) begin
                lookup_hit = 1;
                hit_way = WAY_W'(way);
            end
            if (!invalid_found && !valid[way*SETS+request_set]) begin
                invalid_found = 1;
                replacement_way = WAY_W'(way);
            end
        end
    end
    wire hit_load = state == PROBE && lookup_hit && !request_store;
    wire hit_store = state == PROBE && lookup_hit && request_store;
    wire writeback_complete = state == WRITE_WAIT &&
        (received_count == WORDS || (mem_st_rsp_valid && received_count == WORDS-1));
    wire tag_en = (accept && ram_address) || state == INSTALL ||
        (state == FLUSH_SCAN && flush_valid[1]);
    wire [SET_W-1:0] tag_addr = state == INSTALL ? request_set :
        state == FLUSH_SCAN ? flush_set : lookup_set;
    localparam integer TREE_LEAVES = 2 ** $clog2(LINES);
    reg flush_valid [1:2*TREE_LEAVES-1];
    reg [LINE_W-1:0] flush_index [1:2*TREE_LEAVES-1];
    wire [LINE_W-1:0] flush_choice = flush_index[1];
    wire [SET_W-1:0] flush_set = SET_W'(flush_choice & (SETS-1));
    wire [WAY_W-1:0] flush_way = WAY_W'(flush_choice >> INDEX_BITS);
    always @* begin
        for (integer s = 0; s < TREE_LEAVES; s = s+1) begin
            flush_valid[TREE_LEAVES+s] = (s < LINES) ? dirty[s] : 1'b0;
            flush_index[TREE_LEAVES+s] = LINE_W'(s);
        end
        for (integer n = TREE_LEAVES-1; n > 0; n = n-1) begin
            flush_valid[n] = flush_valid[2*n] | flush_valid[2*n+1];
            flush_index[n] = flush_valid[2*n] ? flush_index[2*n] : flush_index[2*n+1];
        end
    end
    assign st_req_ready = state == IDLE || hit_load;
    assign ld_req_ready = st_req_ready && !st_req_valid;
    wire accept_store = st_req_valid && st_req_ready;
    wire accept_load = ld_req_valid && ld_req_ready;
    wire accept = accept_store || accept_load;
    wire ram_address = lookup_addr[31:28] == 0;
    assign ld_rsp_valid = hit_load || miss_pending;
    assign ld_rsp_payload = hit_load ?
        {request_identity, ram_rdata[32*request_word +: 32]} : miss_response;
    // A hit completes at the same edge that performs its SRAM write.
    assign st_rsp_valid = hit_store || store_pending;

    reg ram_en, ram_we;
    reg [SET_W-1:0] ram_addr;
    reg [LINE_BYTES-1:0] ram_mask;
    reg [LINE_BITS-1:0] ram_wdata;
    reg [WAY_W-1:0] ram_way;
    wire read_all_ways = accept && ram_address;
    wire [LINE_BITS-1:0] ram_rdata = way_rdata[hit_way*LINE_BITS +: LINE_BITS];
    always @* begin
        ram_en = 0;
        ram_we = 0;
        ram_addr = lookup_set;
        ram_mask = 0;
        ram_wdata = 0;
        ram_way = victim_way;
        if (accept && ram_address) ram_en = 1;
        if (hit_store) begin
            ram_en = 1;
            ram_we = 1;
            ram_addr = request_set;
            ram_way = hit_way;
            ram_mask[4*request_word +: 4] = request_mask;
            ram_wdata[32*request_word +: 32] = request_data;
        end
        if (state == FLUSH_SCAN) begin
            ram_en = flush_valid[1];
            ram_addr = flush_set;
            ram_way = flush_way;
        end
        if (state == REFILL && mem_ld_rsp_valid) begin
            ram_en = 1;
            ram_we = 1;
            ram_addr = request_set;
            ram_mask[4*response_word +: 4] = 4'b1111;
            ram_wdata[32*response_word +: 32] = mem_ld_rsp_payload[31:0];
        end
        if (state == INSTALL && request_store) begin
            ram_en = 1;
            ram_we = 1;
            ram_addr = request_set;
            ram_mask[4*request_word +: 4] = request_mask;
            ram_wdata[32*request_word +: 32] = request_data;
        end
    end
    // Every way has its own tag and word banks. Probe reads all ways in
    // parallel; Store/refill/flush enables select only the affected way.
    for (genvar way = 0; way < WAYS; way = way+1) begin : g_way
        wire tag_selected = read_all_ways ||
            (state == INSTALL ? victim_way == WAY_W'(way) : flush_way == WAY_W'(way));
        sram_fakeram #(.DEPTH(SETS), .WIDTH(TAG_W)) tag_ram (
            .clk(clock), .en(tag_en && tag_selected),
            .we(state == INSTALL && victim_way == WAY_W'(way)), .wmask(1'b1),
            .addr(tag_addr), .wdata(request_addr[31 -: TAG_W]),
            .rdata(tag_rdata[way*TAG_W +: TAG_W]));
    for (genvar word = 0; word < WORDS; word = word+1) begin : g_data_word
        wire bank_selected = !ram_we || (|ram_mask[word*4 +: 4]);
        wire bank_en;
        wire [SET_W-1:0] bank_addr;
        (* keep_hierarchy, keep *) cache_group_mask #(.WIDTH(1)) enable_mask (
            .data(ram_en), .enable(bank_selected &&
                (read_all_ways || ram_way == WAY_W'(way))), .masked(bank_en));
        (* keep_hierarchy, keep *) cache_group_mask #(.WIDTH(SET_W)) address_mask (
            .data(ram_addr), .enable(bank_selected), .masked(bank_addr));
        sram_fakeram #(.DEPTH(SETS), .WIDTH(32), .WRITE_GRANULARITY(8)) data_ram (
            .clk(clock), .en(bank_en), .we(ram_we), .wmask(ram_mask[word*4 +: 4]),
            .addr(bank_addr), .wdata(ram_wdata[word*32 +: 32]),
            .rdata(way_rdata[way*LINE_BITS+word*32 +: 32]));
    end
    end
    for (genvar s = 0; s < SETS; s = s+1) begin : g_replacement
        always @(posedge clock) begin
            if (reset) replace_way[s] <= 0;
            else if (state == INSTALL && request_set == SET_W'(s))
                replace_way[s] <= victim_way == WAY_W'(WAYS-1) ?
                    WAY_W'(0) : victim_way + 1'b1;
        end
    end

    assign mem_ld_req_valid = state == REFILL && sent_count < WORDS;
    assign mem_ld_req_payload = {request_identity[GEN_WIDTH+LIDW-1 -: GEN_WIDTH],
        refill_index, (request_addr & ~(32'(LINE_BYTES-1))) + 32'(4*refill_index)};
    assign mem_st_req_valid = (state == WRITEBACK && sent_count < WORDS) || state == IO_SEND;
    assign mem_st_req_payload = state == IO_SEND ?
        {request_addr, request_data, request_mask} :
        {((32'(victim_tag) << (OFFSET_W+INDEX_BITS)) |
          (32'(victim_set) << OFFSET_W)) + 32'(4*sent_count),
         victim_data[32*WORD_W'(sent_count) +: 32], 4'b1111};
    wire read_fire = mem_ld_req_valid && mem_ld_req_ready;
    wire write_fire = mem_st_req_valid && mem_st_req_ready;

    always @(posedge clock) begin
        miss_pending <= 0;
        store_pending <= 0;
        if (accept) begin
            request_addr <= lookup_addr;
            request_data <= st_req_payload[35:4];
            request_mask <= st_req_payload[3:0];
            request_identity <= ld_req_payload[LD_BITS-1:32];
            request_store <= accept_store;
        end
        if (state == VICTIM || (state == PROBE && !lookup_hit)) begin
            victim_data <= way_rdata[
                (state == VICTIM ? victim_way : replacement_way)*LINE_BITS +: LINE_BITS];
            victim_tag <= tag_rdata[
                (state == VICTIM ? victim_way : replacement_way)*TAG_W +: TAG_W];
        end
        if (state == REFILL && mem_ld_rsp_valid && response_word == request_word) begin
            // Publish the critical word immediately; the remaining words still
            // fill the cache, even if the requesting load has been squashed.
            if (!request_store) begin
                miss_pending <= 1;
                miss_response <= {request_identity, mem_ld_rsp_payload[31:0]};
            end
        end
        if (reset) begin
            state <= IDLE;
            miss_pending <= 0;
            store_pending <= 0;
            sent_count <= 0;
            received_count <= 0;
            flushing <= 0;
        end else begin
            case (state)
                IDLE, PROBE: begin
                    if (state == PROBE && !lookup_hit) begin
                        victim_set <= request_set;
                        victim_way <= replacement_way;
                        sent_count <= 0;
                        received_count <= 0;
                        flushing <= 0;
                        state <= (valid[replacement_way*SETS+request_set] &&
                            dirty[replacement_way*SETS+request_set]) ? WRITEBACK : REFILL;
                    end else begin
                        state <= IDLE;
                        if (accept) begin
                            if (!ram_address) begin
                                flushing <= 1;
                                state <= FLUSH_SCAN;
                            end else state <= PROBE;
                        end
                    end
                end
                VICTIM: begin
                    sent_count <= 0;
                    received_count <= 0;
                    state <= WRITEBACK;
                end
                WRITEBACK: begin
                    if (write_fire) begin
                        sent_count <= sent_count + 1'b1;
                        if (sent_count == WORDS-1) state <= WRITE_WAIT;
                    end
                    if (mem_st_rsp_valid) received_count <= received_count + 1'b1;
                end
                WRITE_WAIT: begin
                    if (mem_st_rsp_valid) received_count <= received_count + 1'b1;
                    if (received_count == WORDS ||
                        (mem_st_rsp_valid && received_count == WORDS-1)) begin
                        sent_count <= 0;
                        received_count <= 0;
                        if (flushing) begin
                            state <= FLUSH_SCAN;
                        end else state <= REFILL;
                    end
                end
                REFILL: begin
                    if (read_fire) sent_count <= sent_count + 1'b1;
                    if (mem_ld_rsp_valid) begin
                        received_count <= received_count + 1'b1;
                        if (received_count == WORDS-1) state <= INSTALL;
                    end
                end
                INSTALL: begin
                    if (request_store) store_pending <= 1;
                    state <= IDLE;
                end
                FLUSH_SCAN: begin
                    if (flush_valid[1]) begin
                        victim_set <= flush_set;
                        victim_way <= flush_way;
                        state <= VICTIM;
                    end else state <= IO_SEND;
                end
                IO_SEND: if (write_fire) state <= IO_WAIT;
                IO_WAIT: if (mem_st_rsp_valid) begin
                    store_pending <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
    // Only valid and dirty need reset; tag SRAM contents stay unspecified.
    // Local enables bound the load of the controller's phase signals.
    localparam integer GROUP_SIZE = 16;
    localparam integer GROUPS = (LINES+GROUP_SIZE-1)/GROUP_SIZE;
    wire [LINE_W-1:0] install_line = LINE_W'(victim_way*SETS+request_set);
    wire [LINE_W-1:0] store_line = LINE_W'(hit_way*SETS+request_set);
    wire [LINE_W-1:0] victim_line = LINE_W'(victim_way*SETS+victim_set);
    wire [GROUPS-1:0] install_enable, store_enable, clear_enable;
    for (genvar group = 0; group < GROUPS; group = group+1) begin : g_control_group
        (* keep_hierarchy, keep *) cache_group_mask #(.WIDTH(1)) install_mask (
            .data(state == INSTALL), .enable((install_line >> 4) == group),
            .masked(install_enable[group]));
        (* keep_hierarchy, keep *) cache_group_mask #(.WIDTH(1)) store_mask (
            .data(hit_store), .enable((store_line >> 4) == group),
            .masked(store_enable[group]));
        (* keep_hierarchy, keep *) cache_group_mask #(.WIDTH(1)) clear_mask (
            .data(writeback_complete), .enable((victim_line >> 4) == group),
            .masked(clear_enable[group]));
    end
    for (genvar s = 0; s < LINES; s = s+1) begin : g_control
        wire install_low = (install_line & LINE_W'(15)) == LINE_W'(s%GROUP_SIZE);
        wire store_low = (store_line & LINE_W'(15)) == LINE_W'(s%GROUP_SIZE);
        wire victim_low = (victim_line & LINE_W'(15)) == LINE_W'(s%GROUP_SIZE);
        always @(posedge clock) begin
            if (reset) begin
                dirty[s] <= 0;
                valid[s] <= 0;
            end else begin
                if (store_enable[s/GROUP_SIZE] && store_low) dirty[s] <= 1;
                if (clear_enable[s/GROUP_SIZE] && victim_low) dirty[s] <= 0;
                if (install_enable[s/GROUP_SIZE] && install_low) begin
                    dirty[s] <= request_store;
                    valid[s] <= 1;
                end
            end
        end
    end
endmodule

module cache_group_mask #(parameter integer WIDTH = 1) (
    input wire [WIDTH-1:0] data,
    input wire enable,
    output wire [WIDTH-1:0] masked
);
    assign masked = data & {WIDTH{enable}};
endmodule

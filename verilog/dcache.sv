// Blocking, set-associative write-back cache. Load hits accept one word per cycle;
// a miss transfers a complete line through the pipelined AXI bridge.
module dcache #(
    parameter integer SIZE_BYTES = 4096,
    parameter integer BULK_REFILL = 0, REFILL_HITS = 0,
    parameter integer HIT_UNDER_MISS = 0,
    parameter integer STORE_PIPELINE = 0,
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
    input wire mem_st_rsp_valid,
    output wire line_req_valid, input wire line_req_ready,
    input wire line_rsp_valid,
    input wire [LINE_BYTES*8-1:0] line_rsp_data
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
    (* keep *) reg [3:0] state;
    reg bulk_busy, probe_partial;
    wire bulk_response=BULK_REFILL!=0 && line_rsp_valid;
    assign line_req_valid=BULK_REFILL!=0 && state==REFILL && sent_count==0 && !bulk_busy;
    wire bulk_fire=line_req_valid && line_req_ready;
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
    reg [WORDS-1:0] refill_valid;
    reg refill_hit_pending;
    reg [LD_BITS-1:0] refill_hit_response;
    wire [WORD_W-1:0] refill_load_word=ld_req_payload[2 +: WORD_W];
    wire refill_load_ready=REFILL_HITS!=0 && state==REFILL && refill_valid[refill_load_word] &&
        (ld_req_payload[31:OFFSET_W]==request_addr[31:OFFSET_W]) &&
        !(mem_ld_rsp_valid && response_word==request_word && !request_store);
    wire refill_load_fire=ld_req_valid && refill_load_ready;
    reg [LD_BITS-1:0] miss_response;
    reg hum_pending, hum_probe, hum_retry, hum_held;
    reg [LD_BITS-1:0] hum_request;
    reg [31:0] hum_data;
    wire [SET_W-1:0] hum_set=SET_W'((hum_request[31:0]>>OFFSET_W)&(SETS-1));
    wire [WORD_W-1:0] hum_word=hum_request[2 +: WORD_W];
    wire [WAYS*32-1:0] hum_probe_words;
    wire [WAYS*8*WORD_W-1:0] hum_word_select;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WORD_W), .BRANCHES(WAYS*8))
        distribute_hum_word(hum_word,hum_word_select);
    for (genvar way=0; way<WAYS; way=way+1) begin : g_hum_word
        for (genvar part=0; part<8; part=part+1) begin : g_part
            wire [WORD_W-1:0] selected=hum_word_select[(way*8+part)*WORD_W +: WORD_W];
            assign hum_probe_words[way*32+part*4 +: 4]=way_rdata[way*LINE_BITS+32*selected+part*4 +: 4];
        end
    end
    reg hum_hit;
    reg [31:0] hum_hit_data;
    wire primary_response=hit_load || miss_pending || refill_hit_pending || (bulk_response && !request_store);
    wire hum_response=hum_pending && (hum_held || (hum_probe && hum_hit)) && !primary_response;
    wire hum_can_read=HIT_UNDER_MISS!=0 && state==REFILL && !mem_ld_rsp_valid &&
        !bulk_busy && !bulk_response && !hum_pending && !refill_load_ready;
    wire hum_accept=ld_req_valid && hum_can_read;
    wire replay_hum=hum_pending && hum_retry && state==IDLE;

    wire [1:0] lookup_store_select;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2))
        distribute_lookup_store(st_req_valid && !replay_hum && state!=REFILL,lookup_store_select);
    wire [31:0] lookup_addr;
    for (genvar half=0; half<2; half=half+1) begin : g_lookup_addr
        assign lookup_addr[half*16 +: 16]=lookup_store_select[half]?
            st_req_payload[36+half*16 +: 16]:replay_hum?
            hum_request[half*16 +: 16]:ld_req_payload[half*16 +: 16];
    end
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
    always @* begin
        hum_hit=0; hum_hit_data=0;
        for (integer way=0; way<WAYS; way=way+1)
            if (valid[way*SETS+hum_set] && tag_rdata[way*TAG_W +: TAG_W]==hum_request[31 -: TAG_W]) begin
                hum_hit=1;
                hum_hit_data=hum_probe_words[way*32 +: 32];
            end
    end
    wire hit_load = state == PROBE && lookup_hit && !request_store;
    wire hit_store = state == PROBE && lookup_hit && request_store;
    wire writeback_complete = state == WRITE_WAIT &&
        (received_count == WORDS || (mem_st_rsp_valid && received_count == WORDS-1));
    wire tag_en = ((accept || hum_accept) && ram_address) || state == INSTALL ||
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
    // Separate word banks can probe the next request while the previous
    // Store writes its word. Same-bank collisions retain the normal stall.
    wire store_can_probe=STORE_PIPELINE!=0 && hit_store &&
        lookup_addr[2 +: WORD_W]!=request_word;
    assign st_req_ready = (state == IDLE && !replay_hum) || hit_load || store_can_probe;
    assign ld_req_ready = (st_req_ready && !st_req_valid) || refill_load_ready ||
        hum_can_read;
    wire accept_store = st_req_valid && st_req_ready;
    wire accept_load = ld_req_valid && ld_req_ready && !refill_load_ready && !hum_can_read;
    wire accept = accept_store || accept_load || replay_hum;
    wire ram_address = lookup_addr[31:28] == 0;
    wire [6:0] accept_capture;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(7))
        distribute_accept(accept,accept_capture);
    assign ld_rsp_valid = primary_response || hum_response;
    assign ld_rsp_payload = hum_response ? {hum_request[LD_BITS-1:32],hum_held?hum_data:hum_hit_data} :
        bulk_response ? {request_identity,bulk_word} :
        state == PROBE ? {request_identity, hit_word} : refill_hit_pending ? refill_hit_response : miss_response;
    // A hit completes at the same edge that performs its SRAM write.
    assign st_rsp_valid = hit_store || store_pending;

    reg ram_en, ram_we;
    reg [SET_W-1:0] ram_addr;
    reg [LINE_BYTES-1:0] ram_mask;
    reg [WAY_W-1:0] ram_way;
    wire read_all_ways = (accept || hum_accept) && ram_address;
    // Select the requested word in each way before the tag-dependent way mux.
    // A hit now controls only 32 data bits instead of the complete cache line.
    wire [WAYS*32-1:0] probe_words;
    wire [(WAYS+1)*8*WORD_W-1:0] probe_word_select;
    wire [31:0] bulk_word;
    wire [2*WAY_W-1:0] probe_way_select;
    wire [31:0] hit_word;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WORD_W), .BRANCHES((WAYS+1)*8))
        distribute_probe_word(request_word,probe_word_select);
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WAY_W), .BRANCHES(2))
        distribute_probe_way(hit_way,probe_way_select);
    for (genvar w=0; w<WAYS; w=w+1) begin : g_probe_word
        for (genvar part=0; part<8; part=part+1) begin : g_part
            wire [WORD_W-1:0] word_index=probe_word_select[(w*8+part)*WORD_W +: WORD_W];
            assign probe_words[w*32+part*4 +: 4]=way_rdata[w*LINE_BITS+32*word_index+part*4 +: 4];
        end
    end
    for (genvar part=0; part<8; part=part+1) begin : g_bulk_word
        wire [WORD_W-1:0] word_index=probe_word_select[(WAYS*8+part)*WORD_W +: WORD_W];
        assign bulk_word[part*4 +: 4]=line_rsp_data[32*word_index+part*4 +: 4];
    end
    for (genvar h=0; h<2; h=h+1) begin : g_hit_word
        wire [WAY_W-1:0] way_index=probe_way_select[h*WAY_W +: WAY_W];
        assign hit_word[h*16 +: 16]=probe_words[32*way_index+h*16 +: 16];
    end
    always @* begin
        ram_en = 0;
        ram_we = 0;
        ram_addr = lookup_set;
        ram_mask = 0;
        ram_way = victim_way;
        if ((accept || hum_accept) && ram_address) ram_en = 1;
        if (hit_store) begin
            ram_en = 1;
            ram_we = 1;
            ram_addr = request_set;
            ram_way = hit_way;
            ram_mask[4*request_word +: 4] = request_mask;
        end
        if (STORE_PIPELINE!=0 && state==PROBE && !lookup_hit && probe_partial) begin
            // The preceding Store occupied one bank at this probe's edge.
            // Read the full victim before taking a dirty-line snapshot.
            ram_en=1; ram_we=0; ram_addr=request_set; ram_way=replacement_way;
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
        end
        if (bulk_response) begin
            ram_en=1; ram_we=1; ram_addr=request_set; ram_way=victim_way;
            // The distributed bulk mux selects the complete line below.
            // Leave the ordinary word data independent of the bulk control.
            ram_mask={LINE_BYTES{1'b1}};
        end
        if (state == INSTALL && request_store) begin
            ram_en = 1;
            ram_we = 1;
            ram_addr = request_set;
            ram_mask[4*request_word +: 4] = request_mask;
        end
    end
    localparam integer BANK_CONTROL_BITS=3+WAY_W;
    wire [WAYS*WORDS*BANK_CONTROL_BITS-1:0] bank_control;
    wire [WAYS*WORDS*SET_W-1:0] bank_address, bank_read_address;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(SET_W), .BRANCHES(WAYS*WORDS))
        distribute_bank_read_address(lookup_set,bank_read_address);
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(BANK_CONTROL_BITS), .BRANCHES(WAYS*WORDS))
        distribute_bank_control({ram_way,read_all_ways,ram_we,ram_en},bank_control);
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(SET_W), .BRANCHES(WAYS*WORDS))
        distribute_bank_address(ram_addr,bank_address);
    // Every way has its own tag and word banks. Probe reads all ways in
    // parallel; Store/refill/flush enables select only the affected way.
    wire [WORDS*2-1:0] bulk_select;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(WORDS*2)) distribute_bulk(bulk_response,bulk_select);
    wire [WORDS*32-1:0] bank_wdata;
    wire [WORDS*32-1:0] store_word_data, refill_word_data;
    wire [WORDS*2-1:0] refill_select;
    // The mask selects the word bank. Do not also barrel-shift write data
    // into a zero-filled line: unselected banks never consume their data.
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(32), .BRANCHES(WORDS))
        distribute_store_data(request_data,store_word_data);
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(32), .BRANCHES(WORDS))
        distribute_refill_data(mem_ld_rsp_payload[31:0],refill_word_data);
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(WORDS*2))
        distribute_refill_select(state==REFILL,refill_select);
    for (genvar word=0; word<WORDS; word=word+1) begin : g_write_data
        for (genvar h=0; h<2; h=h+1) begin : g_half
            assign bank_wdata[word*32+h*16 +: 16]=bulk_select[word*2+h]?
                line_rsp_data[word*32+h*16 +: 16]:refill_select[word*2+h]?
                refill_word_data[word*32+h*16 +: 16]:store_word_data[word*32+h*16 +: 16];
        end
    end
    for (genvar way = 0; way < WAYS; way = way+1) begin : g_way
        wire tag_selected = read_all_ways ||
            (state == INSTALL ? victim_way == WAY_W'(way) : flush_way == WAY_W'(way));
        sram_fakeram #(.DEPTH(SETS), .WIDTH(TAG_W)) tag_ram (
            .clk(clock), .en(tag_en && tag_selected),
            .we(state == INSTALL && victim_way == WAY_W'(way)), .wmask(1'b1),
            .addr(tag_addr), .wdata(request_addr[31 -: TAG_W]),
            .rdata(tag_rdata[way*TAG_W +: TAG_W]));
    for (genvar word = 0; word < WORDS; word = word+1) begin : g_data_word
        localparam integer BANK=way*WORDS+word;
        wire local_en=bank_control[BANK*BANK_CONTROL_BITS];
        wire local_we=bank_control[BANK*BANK_CONTROL_BITS+1];
        wire local_read=bank_control[BANK*BANK_CONTROL_BITS+2];
        wire [WAY_W-1:0] local_way=bank_control[BANK*BANK_CONTROL_BITS+3 +: WAY_W];
        wire bank_selected = !local_we || (|ram_mask[word*4 +: 4]);
        wire bank_en, bank_we;
        wire [SET_W-1:0] bank_addr;
        if (STORE_PIPELINE!=0) begin : g_overlap
            wire writes_word=local_we && (|ram_mask[word*4 +: 4]);
            wire reads_bank=local_read && !writes_word;
            assign bank_we=writes_word && local_way==WAY_W'(way);
            (* keep_hierarchy, keep *) cache_group_mask #(.WIDTH(1)) enable_mask (
                .data(local_en), .enable(reads_bank ||
                    (local_way==WAY_W'(way) && (writes_word || (!local_we && !local_read)))),
                .masked(bank_en));
            assign bank_addr=reads_bank ? bank_read_address[BANK*SET_W +: SET_W] :
                bank_address[BANK*SET_W +: SET_W];
        end else begin : g_serial
            assign bank_we=local_we;
            (* keep_hierarchy, keep *) cache_group_mask #(.WIDTH(1)) enable_mask (
                .data(local_en), .enable(bank_selected &&
                    (local_read || local_way==WAY_W'(way))), .masked(bank_en));
            (* keep_hierarchy, keep *) cache_group_mask #(.WIDTH(SET_W)) address_mask (
                .data(bank_address[BANK*SET_W +: SET_W]), .enable(bank_selected), .masked(bank_addr));
        end
        sram_fakeram #(.DEPTH(SETS), .WIDTH(32), .WRITE_GRANULARITY(8)) data_ram (
            .clk(clock), .en(bank_en), .we(bank_we), .wmask(ram_mask[word*4 +: 4]),
            .addr(bank_addr), .wdata(bank_wdata[word*32 +: 32]),
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

    assign mem_ld_req_valid = state == REFILL && sent_count < WORDS && !bulk_busy &&
        !(BULK_REFILL!=0 && sent_count==0 && line_req_ready);
    assign mem_ld_req_payload = {request_identity[GEN_WIDTH+LIDW-1 -: GEN_WIDTH],
        refill_index, (request_addr & ~(32'(LINE_BYTES-1))) + 32'(4*refill_index)};
    assign mem_st_req_valid = (state == WRITEBACK && sent_count < WORDS) || state == IO_SEND;
    wire [8*WORD_W-1:0] writeback_word_select, refill_word_select;
    wire [31:0] writeback_word, refill_word;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WORD_W), .BRANCHES(8))
        distribute_writeback_word(WORD_W'(sent_count),writeback_word_select);
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WORD_W), .BRANCHES(8))
        distribute_refill_word(refill_load_word,refill_word_select);
    for (genvar part=0; part<8; part=part+1) begin : g_victim_word
        wire [WORD_W-1:0] wb_index=writeback_word_select[part*WORD_W +: WORD_W];
        wire [WORD_W-1:0] ld_index=refill_word_select[part*WORD_W +: WORD_W];
        assign writeback_word[part*4 +: 4]=victim_data[32*wb_index+part*4 +: 4];
        assign refill_word[part*4 +: 4]=victim_data[32*ld_index+part*4 +: 4];
    end
    assign mem_st_req_payload = state == IO_SEND ?
        {request_addr, request_data, request_mask} :
        {((32'(victim_tag) << (OFFSET_W+INDEX_BITS)) |
          (32'(victim_set) << OFFSET_W)) + 32'(4*sent_count),
         writeback_word, 4'b1111};
    wire read_fire = mem_ld_req_valid && mem_ld_req_ready;
    wire write_fire = mem_st_req_valid && mem_st_req_ready;

    localparam integer VICTIM_GROUPS=(LINE_BITS+15)/16;
    wire [WAY_W:0] victim_capture={state==VICTIM?victim_way:replacement_way,
        (state==VICTIM || (state==PROBE && !lookup_hit))};
    wire [(VICTIM_GROUPS+1)*(WAY_W+1)-1:0] victim_control;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WAY_W+1), .BRANCHES(VICTIM_GROUPS+1))
        distribute_victim_capture(victim_capture,victim_control);
    for (genvar g=0; g<VICTIM_GROUPS; g=g+1) begin : g_victim_capture
        localparam integer FIRST=16*g;
        localparam integer BITS=(LINE_BITS-FIRST<16)?LINE_BITS-FIRST:16;
        wire [WAY_W-1:0] capture_way=victim_control[g*(WAY_W+1)+1 +: WAY_W];
        always @(posedge clock)
            if (victim_control[g*(WAY_W+1)])
                victim_data[FIRST +: BITS]<=way_rdata[capture_way*LINE_BITS+FIRST +: BITS];
            else if (REFILL_HITS!=0 && state==REFILL && mem_ld_rsp_valid && response_word==WORD_W'(FIRST/32))
                victim_data[FIRST +: BITS]<=mem_ld_rsp_payload[FIRST%32 +: BITS];
    end
    wire [WAY_W-1:0] capture_tag_way=victim_control[VICTIM_GROUPS*(WAY_W+1)+1 +: WAY_W];
    always @(posedge clock)
        // SRAM outputs are invalid when disabled. The partial probe's
        // extra VICTIM phase rereads data only; retain the tag captured in
        // PROBE. MMIO scan still captures the tag read at FLUSH_SCAN.
        if (victim_control[VICTIM_GROUPS*(WAY_W+1)] && (state!=VICTIM || flushing))
            victim_tag<=tag_rdata[capture_tag_way*TAG_W +: TAG_W];

    for (genvar half=0; half<2; half=half+1) begin : g_request_capture
        always @(posedge clock) begin
            if (accept_capture[half]) request_addr[half*16 +: 16]<=lookup_addr[half*16 +: 16];
            if (accept_capture[2+half]) request_data[half*16 +: 16]<=st_req_payload[4+half*16 +: 16];
        end
    end
    always @(posedge clock) begin
        if (accept_capture[4]) request_mask<=st_req_payload[3:0];
        if (accept_capture[5]) request_identity<=replay_hum?hum_request[LD_BITS-1:32]:ld_req_payload[LD_BITS-1:32];
        if (accept_capture[6]) request_store<=accept_store;
    end

    always @(posedge clock) begin
        miss_pending <= 0;
        store_pending <= 0;
        refill_hit_pending<=refill_load_fire;
        if (refill_load_fire)
            refill_hit_response<={ld_req_payload[LD_BITS-1:32],refill_word};
        if (state==PROBE && !lookup_hit) refill_valid<=0;
        if (state==REFILL && mem_ld_rsp_valid) refill_valid[response_word]<=1;
        if (accept) probe_partial<=STORE_PIPELINE!=0 && hit_store;
        if (state == REFILL && mem_ld_rsp_valid && response_word == request_word) begin
            // Publish the critical word immediately; the remaining words still
            // fill the cache, even if the requesting load has been squashed.
            if (!request_store) begin
                miss_pending <= 1;
                miss_response <= {request_identity, mem_ld_rsp_payload[31:0]};
            end
        end
        if (reset) begin
            hum_pending<=0; hum_probe<=0; hum_retry<=0; hum_held<=0;
            state <= IDLE; bulk_busy<=0; probe_partial<=0;
            refill_valid<=0; refill_hit_pending<=0;
            miss_pending <= 0;
            store_pending <= 0;
            sent_count <= 0;
            received_count <= 0;
            flushing <= 0;
        end else begin
            hum_probe<=hum_accept;
            if (hum_accept) begin
                hum_pending<=1; hum_request<=ld_req_payload;
                hum_retry<=0; hum_held<=0;
            end
            if (hum_probe) begin
                if (!hum_hit) hum_retry<=1;
                else if (primary_response) begin hum_held<=1; hum_data<=hum_hit_data; end
            end
            if (hum_response || replay_hum) begin hum_pending<=0; hum_retry<=0; hum_held<=0; end
            case (state)
                IDLE, PROBE: begin
                    if (state == PROBE && !lookup_hit) begin
                        victim_set <= request_set;
                        victim_way <= replacement_way;
                        sent_count <= 0;
                        received_count <= 0;
                        flushing <= 0;
                        state <= (valid[replacement_way*SETS+request_set] &&
                            dirty[replacement_way*SETS+request_set]) ?
                            (STORE_PIPELINE!=0 && probe_partial ? VICTIM : WRITEBACK) : REFILL;
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
                    if (bulk_fire) begin bulk_busy<=1; sent_count<=COUNT_W'(WORDS); end
                    if (bulk_response) begin bulk_busy<=0; received_count<=COUNT_W'(WORDS); state<=INSTALL; end
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
                if (HIT_UNDER_MISS!=0 && state==PROBE && !lookup_hit &&
                    LINE_W'(replacement_way*SETS+request_set)==LINE_W'(s)) valid[s]<=0;
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

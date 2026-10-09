// Three next-line streams. Prefetches use otherwise idle read-channel slots;
// SRAM holds their words until a later blocking-cache refill requests them.
module data_prefetch #(
    parameter integer LINE_BYTES=128, GEN_WIDTH=16, SLOTS=3,
    parameter integer WORDS=LINE_BYTES/4, WORD_W=$clog2(WORDS),
    parameter integer OFFSET_W=$clog2(LINE_BYTES), SLOT_W=$clog2(SLOTS+1),
    parameter integer DC_BITS=GEN_WIDTH+WORD_W+32,
    parameter integer AXI_BITS=DC_BITS+SLOT_W
) (
    input wire clock, reset,
    input wire dc_req_valid, output wire dc_req_ready,
    input wire [DC_BITS-1:0] dc_req_payload,
    output wire dc_rsp_valid, output wire [DC_BITS-1:0] dc_rsp_payload,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [AXI_BITS-1:0] mem_req_payload,
    input wire mem_rsp_valid, input wire [AXI_BITS-1:0] mem_rsp_payload,
    input wire line_req_valid, output wire line_req_ready,
    output reg line_rsp_valid,
    output wire [LINE_BYTES*8-1:0] line_rsp_data,
    input wire write_fire
);
    reg [SLOTS-1:0] valid, busy, dropped;
    reg [31:OFFSET_W] line_tag [0:SLOTS-1];
    reg [GEN_WIDTH-1:0] generation [0:SLOTS-1];
    reg [WORDS-1:0] word_valid [0:SLOTS-1];
    reg [WORD_W:0] sent [0:SLOTS-1], received [0:SLOTS-1];
    reg [SLOT_W-1:0] cursor;
    reg last_valid;
    reg [31:OFFSET_W] last_line;
    integer hit_slot, allocate_slot, issue_slot, choice;
    wire [WORD_W-1:0] dc_word=dc_req_payload[2 +: WORD_W];
    wire [WORD_W-1:0] rsp_word=mem_rsp_payload[32 +: WORD_W];
    wire [SLOT_W-1:0] rsp_slot=mem_rsp_payload[32+WORD_W +: SLOT_W];
    wire demand_response=mem_rsp_valid && rsp_slot==0;
    wire prefetch_response=mem_rsp_valid && rsp_slot!=0;
    wire [31:0] next_line=(dc_req_payload[31:0] & ~32'(LINE_BYTES-1))+32'(LINE_BYTES);
    reg buffer_pending, buffer_held;
    reg [SLOT_W-1:0] buffer_slot;
    reg [WORD_W-1:0] dc_buffer_word;
    reg [GEN_WIDTH+WORD_W-1:0] buffer_identity;
    reg [31:0] held_data;
    wire [SLOTS*LINE_BYTES*8-1:0] ram_lines;
    reg [SLOT_W-1:0] line_slot;
    wire [SLOTS*32-1:0] ram_data;
    wire [31:0] buffered_data=buffer_held?held_data:ram_data[32*buffer_slot +: 32];
    always @* begin
        hit_slot=-1; allocate_slot=-1; issue_slot=-1; choice=0;
        for (integer slot=0; slot<SLOTS; slot=slot+1) begin
            if (valid[slot] && !dropped[slot] && !write_fire &&
                line_tag[slot]==dc_req_payload[31:OFFSET_W] && word_valid[slot][dc_word]) hit_slot=slot;
            if (issue_slot<0 && busy[slot] && sent[slot]<WORDS) issue_slot=slot;
        end
        for (integer offset=0; offset<SLOTS; offset=offset+1) begin
            choice=(int'(cursor)+offset)%SLOTS;
            if (allocate_slot<0 && !busy[choice] && choice!=hit_slot &&
                !(buffer_pending && buffer_slot==SLOT_W'(choice))) allocate_slot=choice;
        end
    end
    assign line_req_ready=hit_slot>=0 && !busy[hit_slot] && !buffer_pending && !write_fire;
    wire line_fire=line_req_valid && line_req_ready;
    localparam integer LINE_GROUPS=LINE_BYTES/2;
    wire [LINE_GROUPS*SLOT_W-1:0] line_select;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(SLOT_W), .BRANCHES(LINE_GROUPS))
        distribute_line_select(line_slot,line_select);
    for (genvar g=0; g<LINE_GROUPS; g=g+1) begin : g_line_read
        wire [SLOT_W-1:0] selected=line_select[g*SLOT_W +: SLOT_W];
        assign line_rsp_data[g*16 +: 16]=ram_lines[int'(selected)*LINE_BYTES*8+g*16 +: 16];
    end
    wire hit_ready=(!buffer_pending || !demand_response) &&
        !(prefetch_response && rsp_slot==SLOT_W'(hit_slot+1));
    wire external_demand=dc_req_valid && hit_slot<0;
    assign dc_req_ready=hit_slot>=0 ? hit_ready : mem_req_ready;
    wire word_fire=dc_req_valid && dc_req_ready;
    wire demand_fire=word_fire || line_fire;
    wire hit_fire=word_fire && hit_slot>=0;
    wire allocate=demand_fire && (!last_valid || last_line!=dc_req_payload[31:OFFSET_W]) &&
        allocate_slot>=0 && next_line[31:28]==0 && !write_fire;
    assign mem_req_valid=external_demand || issue_slot>=0;
    assign mem_req_payload=external_demand ?
        {dc_req_payload[DC_BITS-1:32+WORD_W],{SLOT_W{1'b0}},dc_req_payload[32+WORD_W-1:0]} :
        {generation[issue_slot],SLOT_W'(issue_slot+1),WORD_W'(sent[issue_slot]),
         (32'(line_tag[issue_slot])<<OFFSET_W)+32'(4*sent[issue_slot])};
    wire prefetch_fire=mem_req_valid && mem_req_ready && !external_demand;
    assign dc_rsp_valid=demand_response || buffer_pending;
    assign dc_rsp_payload=demand_response ?
        {mem_rsp_payload[AXI_BITS-1 -: GEN_WIDTH],mem_rsp_payload[32+WORD_W-1:0]} :
        {buffer_identity,buffered_data};
    localparam integer WRITE_GROUPS=(WORDS+3)/4;
    wire [SLOTS*WRITE_GROUPS*32-1:0] write_data;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(32), .BRANCHES(SLOTS*WRITE_GROUPS))
        distribute_write_data(mem_rsp_payload[31:0],write_data);
    for (genvar slot=0; slot<SLOTS; slot=slot+1) begin : g_buffer
        assign ram_data[slot*32 +: 32]=ram_lines[slot*LINE_BYTES*8+32*dc_buffer_word +: 32];
        for (genvar word=0; word<WORDS; word=word+1) begin : g_word
            wire store=prefetch_response && rsp_slot==SLOT_W'(slot+1) && rsp_word==WORD_W'(word);
            wire load=(hit_fire && hit_slot==slot && dc_word==WORD_W'(word)) || (line_fire && hit_slot==slot);
            sram_fakeram #(.DEPTH(1), .WIDTH(32)) words (
                .clk(clock), .en(store || load), .we(store), .wmask(1'b1),
                .addr(1'b0), .wdata(write_data[(slot*WRITE_GROUPS+word/4)*32 +: 32]),
                .rdata(ram_lines[slot*LINE_BYTES*8+word*32 +: 32]));
        end
    end
    always @(posedge clock) begin
        if (reset) begin
            valid<=0; busy<=0; dropped<=0; cursor<=0; last_valid<=0;
            buffer_pending<=0; buffer_held<=0; line_rsp_valid<=0;
            for (integer slot=0; slot<SLOTS; slot=slot+1) begin
                sent[slot]<=0; received[slot]<=0; word_valid[slot]<=0;
            end
        end else begin
            line_rsp_valid<=line_fire;
            if (line_fire) line_slot<=SLOT_W'(hit_slot);
            if (buffer_pending && !demand_response) buffer_pending<=0;
            if (buffer_pending && demand_response && !buffer_held) begin
                held_data<=buffered_data; buffer_held<=1;
            end
            if (hit_fire) begin
                buffer_pending<=1; buffer_held<=0; buffer_slot<=SLOT_W'(hit_slot); dc_buffer_word<=dc_word;
                buffer_identity<=dc_req_payload[DC_BITS-1:32];
            end
            if (demand_fire) begin last_valid<=1; last_line<=dc_req_payload[31:OFFSET_W]; end
            if (prefetch_fire) sent[issue_slot]<=sent[issue_slot]+1'b1;
            if (prefetch_response) begin
                received[rsp_slot-1]<=received[rsp_slot-1]+1'b1;
                word_valid[rsp_slot-1][rsp_word]<=1;
                if (received[rsp_slot-1]==WORDS-1) busy[rsp_slot-1]<=0;
            end
            if (allocate) begin
                valid[allocate_slot]<=1; busy[allocate_slot]<=1; dropped[allocate_slot]<=0;
                line_tag[allocate_slot]<=next_line[31:OFFSET_W];
                generation[allocate_slot]<=dc_req_payload[DC_BITS-1 -: GEN_WIDTH];
                word_valid[allocate_slot]<=0; sent[allocate_slot]<=0; received[allocate_slot]<=0;
                cursor<=SLOT_W'((allocate_slot+1)%SLOTS);
            end
            // Drain old speculative reads before reusing their slot IDs.
            // A writeback invalidates prefetched memory snapshots, including
            // reads still in flight, before any later cache refill can use them.
            if (write_fire) begin valid<=0; dropped<=busy; end
        end
    end
endmodule

module fetch #(
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer GEN_WIDTH = 16,
    parameter [31:0] RESET_PC = 32'h00000000
) (
    input logic clock, reset,
    input logic fetch_redirect_valid,
    input logic [FETCH_REDIRECT_BITS-1:0] fetch_redirect_payload,
    output wire [31:0] lookup_pc,
    input logic pred_taken,
    input logic [31:0] pred_npc,
    output logic ic_req_valid,
    input logic ic_req_ready,
    output logic [IC_REQ_BITS-1:0] ic_req_payload,
    input logic ic_rsp_valid,
    input logic [IC_RSP_BITS-1:0] ic_rsp_payload,
    output logic fetch_valid,
    input logic fetch_ready,
    output logic [DCW-1:0] fetch_count,
    output logic [FETCH_BITS-1:0] fetch_packet
);
    localparam integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1;
    localparam integer DCW = 1;
    localparam integer FETCH_BITS = 96;
    localparam integer FETCH_REDIRECT_BITS = 32 + GEN_WIDTH;
    localparam integer IC_REQ_BITS = GEN_WIDTH + FIDW + DCW + 32;
    localparam integer IC_RSP_BITS = GEN_WIDTH + FIDW + DCW + 32;
    localparam integer QCW=$clog2(FETCH_QUEUE_DEPTH+1);
    localparam integer OCW=$clog2(IFETCH_OUTSTANDING+1);
    localparam integer LINE_WORDS=ICACHE_LINE_BYTES/4;
    localparam integer LINE_W=$clog2(LINE_WORDS);
    // 0 free, 2 waiting, 3 ready. Held requests do not allocate slots yet.
    reg [1:0] state [0:FETCH_QUEUE_DEPTH-1];
    reg [FIDW-1:0] head_q, tail_q;
    reg [QCW-1:0] count_q;
    reg [OCW-1:0] outstanding_q;
    reg [GEN_WIDTH-1:0] fetch_gen;
    reg [31:0] next_pc;
    reg offer_valid;
    reg [DCW-1:0] offer_count;
    reg [31:0] offer_pc, offer_next_pc;
    reg [31:0] offer_npc;
    reg  offer_taken;
    reg [DCW-1:0] create_count, ready_count;
    reg [31:0] create_next_pc;
    reg [31:0] create_npc;
    reg  create_taken;
    reg stop_create, stop_ready;
    wire [31:0] lane_pc, lane_next_pc;
    reg [FETCH_BITS-1:0] ready_packet;
    reg [FETCH_BITS-1:0] out_packet [0:1];
    reg [DCW-1:0] out_count [0:1];
    reg out_head, out_tail;
    reg [1:0] output_count;
    wire [DCW-1:0] request_count=offer_valid?offer_count:create_count;
    wire [31:0] request_pc=offer_valid?offer_pc:next_pc;
    wire [31:0] request_next_pc=offer_valid?offer_next_pc:create_next_pc;
    wire [31:0] request_npc=offer_valid?offer_npc:create_npc;
    wire  request_taken=offer_valid?offer_taken:create_taken;
    wire request_ram=request_pc[31:28]==0;
    wire [3:0] frontend_run;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(4)) distribute_frontend_run (
        !reset && !fetch_redirect_valid,frontend_run);
    wire [FETCH_QUEUE_DEPTH:0] frontend_clear;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(FETCH_QUEUE_DEPTH+1)) distribute_frontend_clear (
        reset || fetch_redirect_valid,frontend_clear);
    wire req_fire=ic_req_valid && ic_req_ready;
    wire create_fire=frontend_run[0] && request_count!=0 &&
        (!request_ram || req_fire);
    wire [DCW-1:0] rsp_count=ic_rsp_payload[32 +: DCW];
    wire [FIDW-1:0] rsp_id=ic_rsp_payload[32+DCW +: FIDW];
    wire [GEN_WIDTH-1:0] rsp_gen=ic_rsp_payload[32+DCW+FIDW +: GEN_WIDTH];
    wire rsp_current=ic_rsp_valid && rsp_gen==fetch_gen;
    localparam integer META_BITS=65;
    wire [META_BITS-1:0] request_meta={request_pc,request_npc,request_taken};
    // Every live slot belongs to fetch_gen; redirect clears all slot states.
    wire response_write=rsp_current && rsp_count!=0 && state[rsp_id]==2;
    wire zero_write=create_fire && !request_ram;
    wire [META_BITS-1:0] head_meta;
    wire [31:0] head_inst;
    // Preparation writes only the free tail; create_fire owns slot validity.
    (* keep_hierarchy *) payload_ram #(.DEPTH(FETCH_QUEUE_DEPTH), .WIDTH(META_BITS)) metadata (
        .clock(clock), .reset(reset), .write_valid(state[tail_q]==0 && request_count!=0),
        .write_addr(tail_q), .write_data(request_meta), .read_addr(head_q), .read_data(head_meta));
    (* keep_hierarchy *) payload_ram #(.DEPTH(FETCH_QUEUE_DEPTH), .WIDTH(32)) instructions (
        .clock(clock), .reset(reset), .write_valid(response_write || zero_write),
        .write_addr(zero_write?tail_q:rsp_id), .write_data(zero_write?32'b0:ic_rsp_payload[31:0]),
        .read_addr(head_q), .read_data(head_inst));
    wire out_fire=fetch_valid && fetch_ready;
    wire direct_fire=output_count==0 && out_fire;
    wire load_output=frontend_run[1] && output_count<2 && ready_count!=0 && !direct_fire;
    wire drain_output=load_output || direct_fire;
    reg [FETCH_BITS-1:0] read_packet;
    reg read_ready;
    integer slot_index;
    begin : g_pc
        assign lane_pc=next_pc;
        pc_increment #(.WORDS(0+1)) inc_next(.pc(next_pc),.next_pc(lane_next_pc));
    end
    assign lookup_pc=next_pc;
    assign ic_req_valid=frontend_run[2] && request_count!=0 && request_ram;
    assign ic_req_payload={fetch_gen,tail_q,request_count,request_pc};
    assign fetch_valid=frontend_run[3] && (output_count!=0 || (ready_count!=0));
    // Keep the output-empty predicate off the wide packet mux's full fanout.
    wire [6:0] packet_bypass;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(7)) distribute_packet_bypass (
        output_count==0,packet_bypass);
    assign fetch_count=packet_bypass[6]?ready_count:out_count[out_head];
    for (genvar chunk=0; chunk<6; chunk=chunk+1) begin : g_output_packet
        assign fetch_packet[chunk*16 +: 16]=packet_bypass[chunk]?
            ready_packet[chunk*16 +: 16]:out_packet[out_head][chunk*16 +: 16];
    end
    always @* begin
        create_count=0; create_next_pc=next_pc; stop_create=0;
        create_npc=0; create_taken=0;
        begin
            create_npc[31:0]=lane_next_pc;
            if (next_pc[31:28]==0 && pred_taken) begin
                create_taken=1;
                create_npc[31:0]=pred_npc[31:0];
            end
            if (!stop_create && int'(count_q)<FETCH_QUEUE_DEPTH &&
                int'(next_pc[2 +: LINE_W])<LINE_WORDS &&
                (next_pc[31:28]!=0 || int'(outstanding_q)<IFETCH_OUTSTANDING)) begin
                create_count=create_count+1'b1;
                create_next_pc=create_npc[31:0];
                if (create_taken) stop_create=1;
            end else stop_create=1;
        end
    end
    // S2: matching response words can be copied straight into the output FIFO.
    always @* begin
        ready_count=0; ready_packet=0; stop_ready=0; slot_index=0;
        read_packet=0; read_ready=0;
        begin
            slot_index=(int'(head_q))%FETCH_QUEUE_DEPTH;
            read_packet={head_meta[64:33],head_inst,head_meta[32:1]};
            read_ready=state[slot_index]==3;
            if (rsp_current && 0<rsp_count && state[slot_index]==2 &&
                    slot_index==(int'(rsp_id))%FETCH_QUEUE_DEPTH) begin
                    read_ready=1;
                    read_packet[63:32]=ic_rsp_payload[31:0];
                end
            ready_packet[FETCH_BITS-1:0]=read_packet;
            if (0>=count_q || !read_ready) stop_ready=1;
            if (!stop_ready) begin
                ready_count=ready_count+1'b1;
                if (head_meta[0]) stop_ready=1;
            end
        end
    end
    localparam integer OUTPUT_GROUPS=(FETCH_BITS+15)/16;
    wire [6:0] offer_capture;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(7)) distribute_offer_capture (
        frontend_run[0] && !create_fire && !offer_valid && ic_req_valid,offer_capture);
    always @(posedge clock)
        if (offer_capture[0]) begin offer_count<=create_count; offer_taken<=create_taken; end
    for (genvar half=0; half<2; half=half+1) begin : g_offer_capture
        always @(posedge clock) begin
            if (offer_capture[1+half]) offer_pc[half*16 +: 16]<=next_pc[half*16 +: 16];
            if (offer_capture[3+half]) offer_next_pc[half*16 +: 16]<=create_next_pc[half*16 +: 16];
            if (offer_capture[5+half]) offer_npc[half*16 +: 16]<=create_npc[half*16 +: 16];
        end
    end
    for (genvar slot=0; slot<2; slot=slot+1) begin : g_output_capture
        wire [OUTPUT_GROUPS-1:0] capture;
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(OUTPUT_GROUPS)) distribute(
            load_output && out_tail==slot,capture);
        for (genvar chunk=0; chunk<OUTPUT_GROUPS; chunk=chunk+1) begin : g_word
            localparam integer OFFSET=16*chunk;
            localparam integer BITS=(FETCH_BITS-OFFSET>16)?16:FETCH_BITS-OFFSET;
            always @(posedge clock)
                if (capture[chunk]) out_packet[slot][OFFSET +: BITS]<=ready_packet[OFFSET +: BITS];
        end
    end
    always @(posedge clock) begin
        if (frontend_clear[FETCH_QUEUE_DEPTH]) begin
            head_q<=0; tail_q<=0; count_q<=0; outstanding_q<=0;
            offer_valid<=0; out_head<=0; out_tail<=0; output_count<=0;
            next_pc<=reset?RESET_PC:fetch_redirect_payload[GEN_WIDTH +: 32];
            fetch_gen<=reset?0:fetch_redirect_payload[GEN_WIDTH-1:0];
        end else begin
            outstanding_q<=outstanding_q+(req_fire?OCW'(request_count):OCW'(0))-
                (rsp_current?OCW'(rsp_count):OCW'(0));
            count_q<=count_q+(create_fire?QCW'(request_count):QCW'(0))-
                (drain_output?QCW'(ready_count):QCW'(0));
            output_count<=output_count+2'(load_output)-2'(out_fire && !direct_fire);
            if (out_fire && !direct_fire) out_head<=~out_head;
            if (load_output) begin
                out_count[out_tail]<=ready_count;
                out_tail<=~out_tail;
            end
            if (drain_output) head_q<=head_q+FIDW'(ready_count);
            if (create_fire) begin
                tail_q<=tail_q+FIDW'(request_count); next_pc<=request_next_pc; offer_valid<=0;
            end else if (!offer_valid && ic_req_valid) begin
                offer_valid<=1;
            end
        end
    end
    for (genvar slot=0; slot<FETCH_QUEUE_DEPTH; slot=slot+1) begin : g_slot
        always @(posedge clock) begin
            if (frontend_clear[slot]) state[slot]<=0;
            else begin
                begin
                    if (rsp_current && 0<rsp_count && state[slot]==2 &&
                        slot==(int'(rsp_id))%FETCH_QUEUE_DEPTH) begin
                        state[slot]<=3;
                    end
                    if (drain_output && 0<ready_count && slot==(int'(head_q))%FETCH_QUEUE_DEPTH)
                        state[slot]<=0;
                    if (create_fire && 0<request_count && slot==(int'(tail_q))%FETCH_QUEUE_DEPTH) begin
                        state[slot]<=request_ram?2:3;
                    end
                end
            end
        end
    end
endmodule

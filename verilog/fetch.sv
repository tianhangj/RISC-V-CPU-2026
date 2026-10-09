module fetch #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer OUTPUT_BYPASS = 0,
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
    localparam integer QCW=$clog2(FETCH_QUEUE_DEPTH+1);
    localparam integer OCW=$clog2(IFETCH_OUTSTANDING+1);
    localparam integer LINE_WORDS=ICACHE_LINE_BYTES/4;
    localparam integer LINE_W=$clog2(LINE_WORDS);
    // 0 free, 2 waiting, 3 ready. Held requests do not allocate slots yet.
    reg [1:0] state [0:FETCH_QUEUE_DEPTH-1];
    reg [31:0] slot_pc [0:FETCH_QUEUE_DEPTH-1], slot_npc [0:FETCH_QUEUE_DEPTH-1];
    reg [31:0] slot_inst [0:FETCH_QUEUE_DEPTH-1];
    reg slot_taken [0:FETCH_QUEUE_DEPTH-1];
    reg [GEN_WIDTH-1:0] slot_gen [0:FETCH_QUEUE_DEPTH-1];
    reg [FIDW-1:0] head_q, tail_q;
    reg [QCW-1:0] count_q;
    reg [OCW-1:0] outstanding_q;
    reg [GEN_WIDTH-1:0] fetch_gen;
    reg [31:0] next_pc;
    reg offer_valid;
    reg [DCW-1:0] offer_count;
    reg [31:0] offer_pc, offer_next_pc;
    reg [DISPATCH_WIDTH*32-1:0] offer_npc;
    reg [DISPATCH_WIDTH-1:0] offer_taken;
    reg [DCW-1:0] create_count, ready_count;
    reg [31:0] create_next_pc;
    reg [DISPATCH_WIDTH*32-1:0] create_npc;
    reg [DISPATCH_WIDTH-1:0] create_taken;
    reg stop_create, stop_ready;
    wire [31:0] lane_pc [0:DISPATCH_WIDTH-1], lane_next_pc [0:DISPATCH_WIDTH-1];
    reg [DISPATCH_WIDTH*FETCH_BITS-1:0] ready_packet;
    reg [DISPATCH_WIDTH*FETCH_BITS-1:0] out_packet [0:1];
    reg [DCW-1:0] out_count [0:1];
    reg out_head, out_tail;
    reg [1:0] output_count;
    wire [DCW-1:0] request_count=offer_valid?offer_count:create_count;
    wire [31:0] request_pc=offer_valid?offer_pc:next_pc;
    wire [31:0] request_next_pc=offer_valid?offer_next_pc:create_next_pc;
    wire [DISPATCH_WIDTH*32-1:0] request_npc=offer_valid?offer_npc:create_npc;
    wire [DISPATCH_WIDTH-1:0] request_taken=offer_valid?offer_taken:create_taken;
    wire request_ram=request_pc[31:28]==0;
    wire req_fire=ic_req_valid && ic_req_ready;
    wire create_fire=!reset && !fetch_redirect_valid && request_count!=0 &&
        (!request_ram || req_fire);
    wire [DCW-1:0] rsp_count=ic_rsp_payload[32*DISPATCH_WIDTH +: DCW];
    wire [FIDW-1:0] rsp_id=ic_rsp_payload[32*DISPATCH_WIDTH+DCW +: FIDW];
    wire [GEN_WIDTH-1:0] rsp_gen=ic_rsp_payload[32*DISPATCH_WIDTH+DCW+FIDW +: GEN_WIDTH];
    wire rsp_current=ic_rsp_valid && rsp_gen==fetch_gen;
    wire out_fire=fetch_valid && fetch_ready;
    wire direct_fire=OUTPUT_BYPASS!=0 && output_count==0 && out_fire;
    wire load_output=!reset && !fetch_redirect_valid && output_count<2 && ready_count!=0 && !direct_fire;
    wire drain_output=load_output || direct_fire;
    reg [FETCH_BITS-1:0] read_packet;
    reg read_ready;
    integer slot_index;
    for (genvar lane=0; lane<DISPATCH_WIDTH; lane=lane+1) begin : g_pc
        if (lane==0) assign lane_pc[lane]=next_pc;
        else pc_increment #(.WORDS(lane)) inc(.pc(next_pc),.next_pc(lane_pc[lane]));
        pc_increment #(.WORDS(lane+1)) inc_next(.pc(next_pc),.next_pc(lane_next_pc[lane]));
    end
    assign lookup_pc=next_pc;
    assign ic_req_valid=!reset && !fetch_redirect_valid && request_count!=0 && request_ram;
    assign ic_req_payload={fetch_gen,tail_q,request_count,request_pc};
    assign fetch_valid=!reset && !fetch_redirect_valid && (output_count!=0 || (OUTPUT_BYPASS!=0 && ready_count!=0));
    assign fetch_count=(OUTPUT_BYPASS!=0 && output_count==0)?ready_count:out_count[out_head];
    assign fetch_packet=(OUTPUT_BYPASS!=0 && output_count==0)?ready_packet:out_packet[out_head];
    always @* begin
        create_count=0; create_next_pc=next_pc; stop_create=0;
        create_npc=0; create_taken=0;
        for (integer lane=0; lane<DISPATCH_WIDTH; lane=lane+1) begin
            create_npc[lane*32 +: 32]=lane_next_pc[lane];
            if (next_pc[31:28]==0 && pred_taken[lane]) begin
                create_taken[lane]=1;
                create_npc[lane*32 +: 32]=pred_npc[lane*32 +: 32];
            end
            if (!stop_create && int'(count_q)+lane<FETCH_QUEUE_DEPTH &&
                int'(next_pc[2 +: LINE_W])+lane<LINE_WORDS &&
                (next_pc[31:28]!=0 || int'(outstanding_q)+lane<IFETCH_OUTSTANDING)) begin
                create_count=create_count+1'b1;
                create_next_pc=create_npc[lane*32 +: 32];
                if (create_taken[lane]) stop_create=1;
            end else stop_create=1;
        end
    end
    // S2: matching response words can be copied straight into the output FIFO.
    always @* begin
        ready_count=0; ready_packet=0; stop_ready=0; slot_index=0;
        read_packet=0; read_ready=0;
        for (integer lane=0; lane<DISPATCH_WIDTH; lane=lane+1) begin
            slot_index=(int'(head_q)+lane)%FETCH_QUEUE_DEPTH;
            read_packet={slot_pc[slot_index],slot_inst[slot_index],slot_npc[slot_index]};
            read_ready=state[slot_index]==3;
            for (integer word_no=0; word_no<DISPATCH_WIDTH; word_no=word_no+1)
                if (rsp_current && word_no<rsp_count && state[slot_index]==2 &&
                    slot_gen[slot_index]==rsp_gen &&
                    slot_index==(int'(rsp_id)+word_no)%FETCH_QUEUE_DEPTH) begin
                    read_ready=1;
                    read_packet[63:32]=ic_rsp_payload[word_no*32 +: 32];
                end
            ready_packet[lane*FETCH_BITS +: FETCH_BITS]=read_packet;
            if (lane>=count_q || !read_ready) stop_ready=1;
            if (!stop_ready) begin
                ready_count=ready_count+1'b1;
                if (slot_taken[slot_index]) stop_ready=1;
            end
        end
    end
    localparam integer OUTPUT_GROUPS=(DISPATCH_WIDTH*FETCH_BITS+15)/16;
    for (genvar slot=0; slot<2; slot=slot+1) begin : g_output_capture
        wire [OUTPUT_GROUPS-1:0] capture;
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(OUTPUT_GROUPS)) distribute(
            load_output && out_tail==slot,capture);
        for (genvar chunk=0; chunk<OUTPUT_GROUPS; chunk=chunk+1) begin : g_word
            localparam integer OFFSET=16*chunk;
            localparam integer BITS=(DISPATCH_WIDTH*FETCH_BITS-OFFSET>16)?16:DISPATCH_WIDTH*FETCH_BITS-OFFSET;
            always @(posedge clock)
                if (capture[chunk]) out_packet[slot][OFFSET +: BITS]<=ready_packet[OFFSET +: BITS];
        end
    end
    always @(posedge clock) begin
        if (reset || fetch_redirect_valid) begin
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
                offer_valid<=1; offer_count<=create_count; offer_pc<=next_pc;
                offer_next_pc<=create_next_pc; offer_npc<=create_npc; offer_taken<=create_taken;
            end
        end
    end
    for (genvar slot=0; slot<FETCH_QUEUE_DEPTH; slot=slot+1) begin : g_slot
        always @(posedge clock) begin
            if (reset || fetch_redirect_valid) state[slot]<=0;
            else begin
                for (integer lane=0; lane<DISPATCH_WIDTH; lane=lane+1) begin
                    if (rsp_current && lane<rsp_count && state[slot]==2 && slot_gen[slot]==rsp_gen &&
                        slot==(int'(rsp_id)+lane)%FETCH_QUEUE_DEPTH) begin
                        slot_inst[slot]<=ic_rsp_payload[lane*32 +: 32]; state[slot]<=3;
                    end
                    if (drain_output && lane<ready_count && slot==(int'(head_q)+lane)%FETCH_QUEUE_DEPTH)
                        state[slot]<=0;
                    if (create_fire && lane<request_count && slot==(int'(tail_q)+lane)%FETCH_QUEUE_DEPTH) begin
                        slot_pc[slot]<=request_pc+32'(4*lane);
                        slot_npc[slot]<=request_npc[lane*32 +: 32]; slot_taken[slot]<=request_taken[lane];
                        slot_gen[slot]<=fetch_gen; state[slot]<=request_ram?2:3;
                        if (!request_ram) slot_inst[slot]<=0;
                    end
                end
            end
        end
    end
endmodule

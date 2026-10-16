module fetch #(
    parameter integer FETCH_WIDTH = 1,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer GEN_WIDTH = 16,
    parameter [31:0] RESET_PC = 32'h00000000
) (
    input wire clock, reset,
    input wire fetch_redirect_valid,
    input wire [31+GEN_WIDTH:0] fetch_redirect_payload,
    output wire [31:0] lookup_pc,
    input wire [FETCH_WIDTH-1:0] pred_taken,
    input wire [32*FETCH_WIDTH-1:0] pred_npc,
    output wire ic_req_valid,
    input wire ic_req_ready,
    output wire [IC_REQ_BITS-1:0] ic_req_payload,
    input wire ic_rsp_valid,
    input wire [IC_RSP_BITS-1:0] ic_rsp_payload,
    output wire fetch_valid,
    input wire fetch_ready,
    output wire [DCW-1:0] fetch_count,
    output wire [96*FETCH_WIDTH-1:0] fetch_packet
);
    localparam integer FIDW=$clog2(FETCH_QUEUE_DEPTH);
    localparam integer DCW=$clog2(FETCH_WIDTH+1);
    localparam integer IC_REQ_BITS=GEN_WIDTH+FIDW+DCW+32;
    localparam integer IC_RSP_BITS=GEN_WIDTH+FIDW+DCW+32*FETCH_WIDTH;
    localparam integer QCW=$clog2(FETCH_QUEUE_DEPTH+1);
    localparam integer OCW=$clog2(IFETCH_OUTSTANDING+1);
    localparam integer LINE_WORDS=ICACHE_LINE_BYTES/4;
    localparam integer LINE_W=$clog2(LINE_WORDS);
    localparam integer BANK_DEPTH=FETCH_QUEUE_DEPTH/FETCH_WIDTH;
    localparam integer BIW=(BANK_DEPTH>1)?$clog2(BANK_DEPTH):1;
    // 0 free, 2 waiting, 3 ready. All live slots belong to fetch_gen.
    reg [1:0] state [0:FETCH_QUEUE_DEPTH-1];
    reg [FIDW-1:0] head_q, tail_q;
    reg [QCW-1:0] count_q;
    reg [OCW-1:0] outstanding_q;
    reg [GEN_WIDTH-1:0] fetch_gen;
    reg [31:0] next_pc;
    reg offer_valid;
    reg [DCW-1:0] offer_count;
    reg [31:0] offer_pc, offer_next_pc;
    reg [FETCH_WIDTH*33-1:0] offer_meta;
    reg [DCW-1:0] create_count;
    reg [31:0] create_next_pc;
    reg [FETCH_WIDTH*33-1:0] create_meta;
    reg stop_create, stop_ready;
    reg [DCW-1:0] ready_count, held_count;
    reg [96*FETCH_WIDTH-1:0] ready_packet, held_packet;
    reg output_held;
    wire [31:0] lane_pc [0:FETCH_WIDTH-1];
    wire [31:0] lane_next_pc [0:FETCH_WIDTH-1];
    wire [DCW-1:0] request_count=offer_valid?offer_count:create_count;
    wire [31:0] request_pc=offer_valid?offer_pc:next_pc;
    wire [31:0] request_next_pc=offer_valid?offer_next_pc:create_next_pc;
    wire [FETCH_WIDTH*33-1:0] request_meta=offer_valid?offer_meta:create_meta;
    wire request_ram=request_pc[31:28]==0;
    wire running=!reset && !fetch_redirect_valid;
    wire req_fire=ic_req_valid && ic_req_ready;
    wire create_fire=running && request_count!=0 && (!request_ram || req_fire);
    wire [DCW-1:0] rsp_count=ic_rsp_payload[32*FETCH_WIDTH +: DCW];
    wire [FIDW-1:0] rsp_id=ic_rsp_payload[32*FETCH_WIDTH+DCW +: FIDW];
    wire [GEN_WIDTH-1:0] rsp_gen=ic_rsp_payload[32*FETCH_WIDTH+DCW+FIDW +: GEN_WIDTH];
    wire rsp_current=ic_rsp_valid && rsp_gen==fetch_gen;
    wire out_fire=fetch_valid && fetch_ready;
    wire [FIDW-1:0] read_slot [0:FETCH_WIDTH-1];
    wire [64:0] head_meta [0:FETCH_WIDTH-1];
    wire [31:0] head_inst [0:FETCH_WIDTH-1];
    wire [FETCH_WIDTH*65-1:0] meta_bank_data [0:FETCH_WIDTH-1];
    wire [FETCH_WIDTH*32-1:0] inst_bank_data [0:FETCH_WIDTH-1];

    assign lookup_pc=next_pc;
    assign ic_req_valid=running && request_count!=0 && request_ram;
    assign ic_req_payload={fetch_gen,tail_q,request_count,request_pc};
    assign fetch_valid=running && fetch_count!=0;
    assign fetch_count=output_held?held_count:ready_count;
    assign fetch_packet=output_held?held_packet:ready_packet;
    always @(posedge clock) begin
        if (reset || fetch_redirect_valid) output_held<=0;
        else if (out_fire) output_held<=0;
        else if (!output_held && ready_count!=0) begin
            output_held<=1; held_count<=ready_count; held_packet<=ready_packet;
        end
    end
    for (genvar lane=0; lane<FETCH_WIDTH; lane=lane+1) begin : g_lane
        pc_increment #(.WORDS(lane)) inc_pc(.pc(next_pc),.next_pc(lane_pc[lane]));
        pc_increment #(.WORDS(lane+1)) inc_next(.pc(next_pc),.next_pc(lane_next_pc[lane]));
        assign read_slot[lane]=head_q+FIDW'(lane);
        assign head_meta[lane]=meta_bank_data[int'(read_slot[lane])%FETCH_WIDTH][lane*65 +: 65];
        assign head_inst[lane]=inst_bank_data[int'(read_slot[lane])%FETCH_WIDTH][lane*32 +: 32];
    end
    // Consecutive slots occupy distinct banks, allowing two writes without
    // multiport SRAM. Each bank retains the scalar SRAM bypass semantics.
    for (genvar bank=0; bank<FETCH_WIDTH; bank=bank+1) begin : g_bank
        reg meta_write, inst_write;
        reg [BIW-1:0] meta_addr, inst_addr;
        reg [64:0] meta_data;
        reg [31:0] inst_data;
        wire [FETCH_WIDTH*BIW-1:0] read_addr;
        for (genvar lane=0; lane<FETCH_WIDTH; lane=lane+1) begin : g_read
            assign read_addr[lane*BIW +: BIW]=BIW'(int'(read_slot[lane])/FETCH_WIDTH);
        end
        always @* begin
            meta_write=0; inst_write=0; meta_addr=0; inst_addr=0; meta_data=0; inst_data=0;
            for (integer lane=0; lane<FETCH_WIDTH; lane=lane+1) begin
                if (create_fire && lane<int'(request_count) &&
                    ((int'(tail_q)+lane)%FETCH_QUEUE_DEPTH)%FETCH_WIDTH==bank) begin
                    meta_write=1;
                    meta_addr=BIW'(((int'(tail_q)+lane)%FETCH_QUEUE_DEPTH)/FETCH_WIDTH);
                    meta_data={request_pc+32'(lane*4),request_meta[lane*33 +: 33]};
                    if (!request_ram) begin inst_write=1; inst_addr=meta_addr; inst_data=0; end
                end
                if (rsp_current && lane<int'(rsp_count) &&
                    ((int'(rsp_id)+lane)%FETCH_QUEUE_DEPTH)%FETCH_WIDTH==bank) begin
                    inst_write=1;
                    inst_addr=BIW'(((int'(rsp_id)+lane)%FETCH_QUEUE_DEPTH)/FETCH_WIDTH);
                    inst_data=ic_rsp_payload[lane*32 +: 32];
                end
            end
        end
        payload_ram #(.DEPTH(BANK_DEPTH),.WIDTH(65),.READ_PORTS(FETCH_WIDTH)) metadata (
            .clock(clock),.reset(reset),.write_valid(meta_write),.write_addr(meta_addr),.write_data(meta_data),
            .read_addr(read_addr),.read_data(meta_bank_data[bank]));
        payload_ram #(.DEPTH(BANK_DEPTH),.WIDTH(32),.READ_PORTS(FETCH_WIDTH)) instructions (
            .clock(clock),.reset(reset),.write_valid(inst_write),.write_addr(inst_addr),.write_data(inst_data),
            .read_addr(read_addr),.read_data(inst_bank_data[bank]));
    end
    always @* begin
        create_count=0; create_next_pc=next_pc; create_meta=0; stop_create=0;
        for (integer lane=0; lane<FETCH_WIDTH; lane=lane+1) begin
            create_meta[lane*33 +: 33]={lane_next_pc[lane],1'b0};
            if (next_pc[31:28]==0 && pred_taken[lane])
                create_meta[lane*33 +: 33]={pred_npc[lane*32 +: 32],1'b1};
            if (!stop_create && int'(count_q)+lane<FETCH_QUEUE_DEPTH &&
                int'(next_pc[2 +: LINE_W])+lane<LINE_WORDS &&
                (next_pc[31:28]!=0 || int'(outstanding_q)+lane<IFETCH_OUTSTANDING)) begin
                create_count=create_count+1'b1;
                create_next_pc=create_meta[lane*33+1 +: 32];
                if (create_meta[lane*33]) stop_create=1;
            end else stop_create=1;
        end
    end
    reg read_ready;
    reg [95:0] read_packet;
    always @* begin
        ready_count=0; ready_packet=0; stop_ready=0; read_ready=0; read_packet=0;
        for (integer lane=0; lane<FETCH_WIDTH; lane=lane+1) begin
            read_packet={head_meta[lane][64:33],head_inst[lane],head_meta[lane][32:1]};
            read_ready=state[read_slot[lane]]==3;
            for (integer word_no=0; word_no<FETCH_WIDTH; word_no=word_no+1)
                if (rsp_current && word_no<int'(rsp_count) && state[read_slot[lane]]==2 &&
                    read_slot[lane]==FIDW'(int'(rsp_id)+word_no)) begin
                    read_ready=1;
                    read_packet[63:32]=ic_rsp_payload[word_no*32 +: 32];
                end
            ready_packet[lane*96 +: 96]=read_packet;
            if (lane>=int'(count_q) || !read_ready) stop_ready=1;
            if (!stop_ready) begin
                ready_count=ready_count+1'b1;
                if (head_meta[lane][0]) stop_ready=1;
            end
        end
    end
    always @(posedge clock) begin
        if (reset || fetch_redirect_valid) begin
            head_q<=0; tail_q<=0; count_q<=0; outstanding_q<=0; offer_valid<=0;
            next_pc<=reset?RESET_PC:fetch_redirect_payload[GEN_WIDTH +: 32];
            fetch_gen<=reset?0:fetch_redirect_payload[GEN_WIDTH-1:0];
        end else begin
            outstanding_q<=outstanding_q+(req_fire?OCW'(request_count):OCW'(0))-
                (rsp_current?OCW'(rsp_count):OCW'(0));
            count_q<=count_q+(create_fire?QCW'(request_count):QCW'(0))-
                (out_fire?QCW'(fetch_count):QCW'(0));
            if (out_fire) head_q<=head_q+FIDW'(fetch_count);
            if (create_fire) begin
                tail_q<=tail_q+FIDW'(request_count); next_pc<=request_next_pc; offer_valid<=0;
            end else if (!offer_valid && ic_req_valid) begin
                offer_valid<=1; offer_pc<=next_pc; offer_count<=create_count;
                offer_next_pc<=create_next_pc; offer_meta<=create_meta;
            end
        end
    end
    for (genvar slot=0; slot<FETCH_QUEUE_DEPTH; slot=slot+1) begin : g_slot
        always @(posedge clock) begin
            if (reset || fetch_redirect_valid) state[slot]<=0;
            else begin
                for (integer lane=0; lane<FETCH_WIDTH; lane=lane+1) begin
                    if (rsp_current && lane<int'(rsp_count) && state[slot]==2 &&
                        FIDW'(int'(rsp_id)+lane)==FIDW'(slot)) state[slot]<=3;
                    if (out_fire && lane<int'(fetch_count) &&
                        FIDW'(int'(head_q)+lane)==FIDW'(slot)) state[slot]<=0;
                    if (create_fire && lane<int'(request_count) &&
                        FIDW'(int'(tail_q)+lane)==FIDW'(slot)) state[slot]<=request_ram?2:3;
                end
            end
        end
    end
endmodule

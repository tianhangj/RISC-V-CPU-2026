module lsu #(
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48,
    parameter integer LQ_DEPTH = 4,
    parameter integer SQ_DEPTH = 8,
    parameter integer LOAD_OUTSTANDING = 4,
    parameter integer GEN_WIDTH = 16
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [GEN_WIDTH-1:0] current_gen,
    input logic disp_valid,
    input logic [MEM_ALLOC_BITS-1:0] disp_lsq,
    output wire lq_has_free, sq_has_free,
    output logic [LIDW-1:0] lq_alloc_id,
    output logic [SIDW-1:0] sq_alloc_id,
    input wire store_data_valid,
    input wire [PW-1:0] store_psrc,
    input wire [2:0] forward_valid,
    input wire [3*PW-1:0] forward_pdst,
    input wire [3*32-1:0] forward_value,
    input logic exec_valid,
    input wire read_exec_valid,
    output logic exec_ready,
    input logic [MEM_EXEC_BITS-1:0] exec_payload,
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload,
    input logic st_start_valid,
    input logic [SIDW-1:0] st_start_id,
    output logic st_done_valid,
    output logic ld_req_valid,
    input logic ld_req_ready,
    output logic [LD_REQ_BITS-1:0] ld_req_payload,
    input logic ld_rsp_valid,
    input logic [LD_RSP_BITS-1:0] ld_rsp_payload,
    output logic st_req_valid,
    input logic st_req_ready,
    output logic [WRITE_REQ_BITS-1:0] st_req_payload,
    input logic st_rsp_valid
);
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1;
    localparam integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1;
    localparam integer MIDW = (LIDW > SIDW) ? LIDW : SIDW;
    localparam integer LQ_CW = $clog2(LQ_DEPTH + 1);
    localparam integer SQ_CW = $clog2(SQ_DEPTH + 1);
    localparam integer TAG_BITS = RW;
    localparam integer MEM_ALLOC_BITS = 1 + MIDW + TAG_BITS + PW;
    localparam integer MEM_EXEC_BITS = TAG_BITS + 3 + MIDW + 96;
    localparam integer RESULT_BITS = TAG_BITS + PW + 32;
    localparam integer LD_REQ_BITS = GEN_WIDTH + LIDW + 32;
    localparam integer LD_RSP_BITS = GEN_WIDTH + LIDW + 32;
    localparam integer WRITE_REQ_BITS = 68;
    localparam integer OCW = $clog2(LOAD_OUTSTANDING + 1);
    logic [LQ_DEPTH-1:0] lq_valid;
    logic [SQ_DEPTH-1:0] sq_valid, sq_addr_ready, sq_reported;
    logic [SQ_DEPTH-1:0] sq_committed, sq_data_ready;
    reg [PW-1:0] sq_psrc [0:SQ_DEPTH-1];
    reg [SIDW-1:0] commit_fifo [0:SQ_DEPTH-1];
    (* keep *) reg [SIDW-1:0] commit_head, commit_tail;
    reg [SQ_DEPTH-1:0] sq_younger [0:SQ_DEPTH-1];
    (* keep *) reg [SQ_CW-1:0] commit_count;
    logic [2:0] lq_state [0:LQ_DEPTH-1]; // 0 waiting AGU, 1 addr, 2 R, 3 data, 4 result queued
    logic [TAG_BITS-1:0] lq_rob [0:LQ_DEPTH-1], sq_rob [0:SQ_DEPTH-1];
    logic [PW-1:0] lq_pdst [0:LQ_DEPTH-1];
    logic [2:0] lq_op [0:LQ_DEPTH-1], sq_op [0:SQ_DEPTH-1];
    logic [31:0] lq_addr [0:LQ_DEPTH-1], lq_data [0:LQ_DEPTH-1];
    logic [31:0] sq_addr [0:SQ_DEPTH-1], sq_data [0:SQ_DEPTH-1];
    logic [GEN_WIDTH-1:0] lq_gen [0:LQ_DEPTH-1];
    logic [OCW-1:0] outstanding_q;
    logic [LQ_DEPTH-1:0] lq_reserved;
    logic [SQ_DEPTH-1:0] sq_reserved;
    integer alloc_l, alloc_s, chosen_load, chosen_result;
    logic result_is_store;
    logic [RESULT_BITS-1:0] result_q;
    logic [RESULT_BITS-1:0] selected_result;
    logic result_busy, result_load;
    logic [LIDW-1:0] result_load_id;
    logic offer_valid;
    logic [LIDW-1:0] offer_id;
    logic [GEN_WIDTH-1:0] offer_gen;
    wire [LIDW-1:0] request_id = offer_valid ? offer_id : LIDW'(chosen_load);
    wire [GEN_WIDTH-1:0] request_gen = offer_valid ? offer_gen : current_gen;
    logic write_sent;
    wire [SIDW-1:0] active_write_id = (commit_fifo[commit_head]);
    wire write_complete=st_rsp_valid && (commit_count!=0);
    wire [TAG_BITS-1:0] exec_rob = exec_payload[MEM_EXEC_BITS-1 -: TAG_BITS];
    wire [2:0] exec_op = exec_payload[96+MIDW +: 3];
    wire [MIDW-1:0] exec_id = exec_payload[96 +: MIDW];
    (* keep *) wire [31:0] exec_addr;
    (* keep_hierarchy, keep *) word_adder address_adder(
        .a(exec_payload[95:64]), .b(exec_payload[63:32]), .carry_in(1'b0), .sum(exec_addr));
    wire [2*LQ_DEPTH-1:0] exec_ram_control;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2*LQ_DEPTH))
        distribute_exec_ram(exec_addr[31:28]==0,exec_ram_control);
    wire [31:0] exec_data = exec_payload[31:0];
    wire next_write=write_complete && commit_count>1;
    wire [SIDW-1:0] next_write_id=commit_fifo[SIDW'(commit_head+1'b1)];
    wire [66:0] write_candidates [0:1];
    wire [4:0] write_choice;
    wire [66:0] write_offer;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(5))
        distribute_write_choice(next_write,write_choice);
    // Prepare both FIFO heads before the cache completion arrives. Its late
    // selection then drives five small muxes, not the SQ's full read decoder.
    for (genvar port=0; port<2; port=port+1) begin : g_store_offer
        wire [SIDW-1:0] id=(port==0)?active_write_id:next_write_id;
        wire [5*SQ_DEPTH-1:0] select;
        reg [66:0] word;
        for (genvar st=0; st<SQ_DEPTH; st=st+1) begin : g_select
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(5))
                distribute(id==SIDW'(st),select[st*5 +: 5]);
        end
        always @* begin
            word=0;
            for (integer st=0; st<SQ_DEPTH; st=st+1)
                for (integer bit_no=0; bit_no<67; bit_no=bit_no+1)
                    word[bit_no]=word[bit_no] |
                        (({sq_addr[st],sq_data[st],sq_op[st]} >> bit_no) & select[st*5+bit_no/16]);
        end
        assign write_candidates[port]=word;
    end
    for (genvar chunk=0; chunk<5; chunk=chunk+1) begin : g_store_choice
        localparam integer BASE=chunk*16;
        localparam integer BITS=(67-BASE>16)?16:67-BASE;
        assign write_offer[BASE +: BITS]=write_choice[chunk]?
            write_candidates[1][BASE +: BITS]:write_candidates[0][BASE +: BITS];
    end
    wire [31:0] write_addr=write_offer[66:35];
    wire [31:0] write_data=write_offer[34:3];
    wire [2:0] write_op=write_offer[2:0];
    wire [LIDW-1:0] rsp_id = ld_rsp_payload[32 +: LIDW];
    wire [GEN_WIDTH-1:0] rsp_gen = ld_rsp_payload[32+LIDW +: GEN_WIDTH];
    wire req_fire = ld_req_valid && ld_req_ready;
    wire result_fire = result_valid && result_ready;
    wire [LQ_DEPTH-1:0] response_slot;
    wire [2*LQ_DEPTH-1:0] response_identity_select;
    wire [TAG_BITS-1:0] response_tags [0:LQ_DEPTH-1];
    wire [PW-1:0] response_destinations [0:LQ_DEPTH-1];
    reg [TAG_BITS-1:0] response_tag;
    reg [PW-1:0] response_pdst;
    for (genvar slot=0; slot<LQ_DEPTH; slot=slot+1) begin : g_response_identity
        assign response_slot[slot]=ld_rsp_valid && rsp_id==LIDW'(slot) &&
            lq_valid[slot] && lq_state[slot]==2 && lq_gen[slot]==rsp_gen;
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2)) distribute_identity(
            response_slot[slot],response_identity_select[2*slot +: 2]);
        assign response_tags[slot]=lq_rob[slot] & {TAG_BITS{response_identity_select[2*slot]}};
        assign response_destinations[slot]=lq_pdst[slot] & {PW{response_identity_select[2*slot+1]}};
    end
    always @* begin
        response_tag=0; response_pdst=0;
        for (integer slot=0; slot<LQ_DEPTH; slot=slot+1) begin
            response_tag=response_tag | response_tags[slot];
            response_pdst=response_pdst | response_destinations[slot];
        end
    end
    (* keep *) wire response_matches=|response_slot;
    wire response_priority=response_matches;
    wire [3:0] response_choice;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(4))
        distribute_response_choice(response_priority,response_choice);
    wire [31:0] response_value=load_extend(lq_op[rsp_id],lq_addr[rsp_id][1:0],ld_rsp_payload[31:0]);
    wire selected_survives = !squash_valid ||
        RW'(selected_result[RESULT_BITS-1 -: TAG_BITS]-rob_head) <= RW'(squash_tag-rob_head);

    function automatic [3:0] byte_mask(input [2:0] op, input [1:0] offset);
        begin
            case (op)
                0, 3, 5: byte_mask = 4'b0001 << offset;
                1, 4, 6: byte_mask = 4'b0011 << offset;
                default: byte_mask = 4'b1111;
            endcase
        end
    endfunction
    function automatic [31:0] load_extend(input [2:0] op, input [1:0] offset, input [31:0] word);
        reg [31:0] shifted;
        begin
            shifted = word >> (offset * 8);
            case (op)
                0: load_extend = {{24{shifted[7]}}, shifted[7:0]};
                1: load_extend = {{16{shifted[15]}}, shifted[15:0]};
                2: load_extend = shifted;
                3: load_extend = {24'b0, shifted[7:0]};
                4: load_extend = {16'b0, shifted[15:0]};
                default: load_extend = 0;
            endcase
        end
    endfunction

    assign lq_has_free = |(~lq_valid);
    assign sq_has_free = |(~sq_valid);
    always_comb begin
        lq_alloc_id = 0;
        sq_alloc_id = 0;
        lq_reserved = 0;
        sq_reserved = 0;
        begin
            alloc_l = -1;
            alloc_s = -1;
            for (int l = 0; l < LQ_DEPTH; l = l + 1)
                if (alloc_l < 0 && !lq_valid[l] && !lq_reserved[l]) alloc_l = l;
            for (int s = 0; s < SQ_DEPTH; s = s + 1)
                if (alloc_s < 0 && !sq_valid[s] && !sq_reserved[s]) alloc_s = s;
            if (alloc_l >= 0) begin
                lq_alloc_id[LIDW-1:0] = alloc_l;
                lq_reserved[alloc_l] = 1;
            end
            if (alloc_s >= 0) begin
                sq_alloc_id[SIDW-1:0] = alloc_s;
                sq_reserved[alloc_s] = 1;
            end
        end
    end
    localparam integer RESULT_COUNT=LQ_DEPTH+SQ_DEPTH;
    localparam integer RESULT_ID_W=$clog2(RESULT_COUNT);
    reg [LIDW-1:0] load_rr;
    reg [RESULT_ID_W-1:0] result_rr;
    wire [LQ_DEPTH-1:0] load_ready;
    wire [LQ_DEPTH-1:0] load_after, load_select;
    wire [LQ_DEPTH:0] load_prefix, load_after_prefix;
    wire [RESULT_COUNT-1:0] result_ready_map, result_after, result_select;
    localparam integer RESULT_GROUPS=(RESULT_BITS+15)/16;
    wire [RESULT_COUNT*RESULT_GROUPS-1:0] result_data_select;
    wire [RESULT_GROUPS-1:0] result_held_select;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(RESULT_GROUPS))
        distribute_result_held(result_busy,result_held_select);
    wire [RESULT_COUNT:0] result_prefix, result_after_prefix;
    assign load_prefix[0]=0;
    assign load_after_prefix[0]=0;
    assign result_prefix[0]=0;
    assign result_after_prefix[0]=0;
    for (genvar l=0; l<LQ_DEPTH; l=l+1) begin : g_load_priority
        assign load_after[l]=load_ready[l] && LIDW'(l)>=load_rr;
        assign load_prefix[l+1]=load_prefix[l] || load_ready[l];
        assign load_after_prefix[l+1]=load_after_prefix[l] || load_after[l];
        assign load_select[l]=(|load_after) ?
            (load_after[l] && !load_after_prefix[l]) : (load_ready[l] && !load_prefix[l]);
    end
    for (genvar r=0; r<RESULT_COUNT; r=r+1) begin : g_result_priority
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(RESULT_GROUPS))
            distribute_data(result_select[r],result_data_select[r*RESULT_GROUPS +: RESULT_GROUPS]);
        if (r<LQ_DEPTH) begin : g_load
            assign result_ready_map[r]=lq_valid[r] && lq_state[r]==3;
        end else begin : g_store
            assign result_ready_map[r]=sq_valid[r-LQ_DEPTH] && sq_addr_ready[r-LQ_DEPTH] &&
                sq_data_ready[r-LQ_DEPTH] && !sq_reported[r-LQ_DEPTH];
        end
        assign result_after[r]=result_ready_map[r] && RESULT_ID_W'(r)>=result_rr;
        assign result_prefix[r+1]=result_prefix[r] || result_ready_map[r];
        assign result_after_prefix[r+1]=result_after_prefix[r] || result_after[r];
        assign result_select[r]=(|result_after) ?
            (result_after[r] && !result_after_prefix[r]) : (result_ready_map[r] && !result_prefix[r]);
    end
    wire [LQ_DEPTH-1:0] load_forward_valid;
    wire [31:0] load_forward_value [0:LQ_DEPTH-1];
    wire [SQ_DEPTH-1:0] store_before_head;
    wire [3:0] store_mask [0:SQ_DEPTH-1];
    wire [31:0] aligned_store [0:SQ_DEPTH-1];
    wire forward_load=chosen_load>=0 && load_forward_valid[LIDW'(chosen_load)];
    for (genvar st=0; st<SQ_DEPTH; st=st+1) begin : g_store_order
        assign store_before_head[st]=sq_rob[st]<rob_head;
        assign store_mask[st]=byte_mask(sq_op[st],sq_addr[st][1:0]);
        assign aligned_store[st]=sq_data[st] << (8*sq_addr[st][1:0]);
        always_ff @(posedge clock) begin
            if (reset) sq_younger[st]<=0;
            else if (disp_valid && !squash_valid && disp_lsq[MEM_ALLOC_BITS-1]) begin
                if (disp_lsq[PW+TAG_BITS +: MIDW]==MIDW'(st))
                    sq_younger[st]<=0;
                else
                    sq_younger[st][disp_lsq[PW+TAG_BITS +: MIDW]]<=sq_valid[st];
            end
        end
    end
    for (genvar l=0; l<LQ_DEPTH; l=l+1) begin : g_load_forward
        wire [3:0] mask=byte_mask(lq_op[l],lq_addr[l][1:0]);
        wire before_head=lq_rob[l]<rob_head;
        wire [SQ_DEPTH-1:0] unknown_address, overlapping, newest, usable;
        wire [31:0] selected_data [0:SQ_DEPTH-1];
        reg [31:0] word;
        for (genvar st=0; st<SQ_DEPTH; st=st+1) begin : g_match
            // The wrap comparison orders live ROB entries; committed Stores
            // precede them. Allocation order selects the youngest match even
            // after a committed Store's ROB tag has been reused.
            wire older=sq_committed[st] ||
                ((sq_rob[st]<lq_rob[l]) ^ store_before_head[st] ^ before_head);
            wire eligible=sq_valid[st] && older;
            wire [1:0] data_select;
            assign unknown_address[st]=eligible && !sq_addr_ready[st];
            assign overlapping[st]=eligible && sq_addr_ready[st] &&
                sq_addr[st][31:2]==lq_addr[l][31:2] && (store_mask[st] & mask)!=0;
            assign newest[st]=overlapping[st] && !(|(sq_younger[st] & overlapping));
            assign usable[st]=newest[st] && sq_data_ready[st] &&
                (store_mask[st] & mask)==mask;
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2))
                distribute_store(newest[st],data_select);
            assign selected_data[st][15:0]=aligned_store[st][15:0] & {16{data_select[0]}};
            assign selected_data[st][31:16]=aligned_store[st][31:16] & {16{data_select[1]}};
        end
        always @* begin
            word=0;
            for (integer st=0; st<SQ_DEPTH; st=st+1) word=word | selected_data[st];
        end
        assign load_forward_value[l]=word;
        assign load_forward_valid[l]=lq_state[l]==1 && !(|unknown_address) &&
            (|usable) && lq_addr[l][31:28]==0;
        assign load_ready[l]=lq_valid[l] && lq_state[l]==1 && !(|unknown_address) &&
            (!(|overlapping) || load_forward_valid[l]) &&
            !(offer_valid && offer_id==LIDW'(l));
    end
    always_comb begin
        chosen_load=-1;
        for (int l=0; l<LQ_DEPTH; l=l+1)
            if (load_select[l]) chosen_load=l;
    end
    always_comb begin
        chosen_result=-1;
        result_is_store=0;
        selected_result=0;
        for (int r=0; r<RESULT_COUNT; r=r+1) begin
            if (result_select[r]) begin
                result_is_store=r>=LQ_DEPTH;
                chosen_result=(r>=LQ_DEPTH)?r-LQ_DEPTH:r;
            end
            for (int bit_no=0; bit_no<RESULT_BITS; bit_no=bit_no+1)
                if (r<LQ_DEPTH)
                    selected_result[bit_no] |=
                        (({lq_rob[r],lq_pdst[r],lq_data[r]} >> bit_no) & result_data_select[r*RESULT_GROUPS+bit_no/16]);
                else
                    selected_result[bit_no] |=
                        (({sq_rob[r-LQ_DEPTH],{PW{1'b0}},32'b0} >> bit_no) & result_data_select[r*RESULT_GROUPS+bit_no/16]);
        end
        if (response_matches) begin
            chosen_result=int'(rsp_id); result_is_store=0;
        end
        if (response_choice[0]) selected_result[0 +: 16]=response_value[0 +: 16];
        if (response_choice[1]) selected_result[16 +: 16]=response_value[16 +: 16];
        if (response_choice[2]) selected_result[32 +: PW]=response_pdst;
        if (response_choice[3]) selected_result[32+PW +: TAG_BITS]=response_tag;
    end
    assign exec_ready = 1'b1;
    assign result_valid = result_busy ||
        (response_priority || (|result_ready_map));
    for (genvar chunk=0; chunk<RESULT_GROUPS; chunk=chunk+1) begin : g_result_payload
        localparam integer BASE=chunk*16;
        localparam integer BITS=(RESULT_BITS-BASE>16)?16:RESULT_BITS-BASE;
        assign result_payload[BASE +: BITS]=result_held_select[chunk]?
            result_q[BASE +: BITS]:selected_result[BASE +: BITS];
    end
    // Offers address RAM only. A read accepted on the squash edge is harmless:
    // its original generation still identifies the later, discarded response.
    // The single-issue path bypasses an empty request buffer. If the cache or
    // read credits stall it, the selected address/gen/id are held from the edge.
    assign ld_req_valid = (offer_valid || (chosen_load >= 0 && !forward_load)) &&
        outstanding_q < LOAD_OUTSTANDING;
    assign ld_req_payload = {request_gen, request_id, lq_addr[request_id] & 32'hfffffffc};
    // ROB authorization already identifies a completed, non-speculative Store.
    // Send it immediately; the commit FIFO and write_sent retain the offer if the cache
    // applies backpressure or until its response arrives.
    assign st_req_valid = (commit_count!=0) && (!write_sent || next_write);
    assign st_req_payload = {write_addr & 32'hfffffffc,
        write_data << (8*write_addr[1:0]), byte_mask(write_op, write_addr[1:0])};
    assign st_done_valid = (st_start_valid && sq_addr[st_start_id][31:28]==0) ||
        (write_complete && sq_addr[active_write_id][31:28]!=0);

    always_ff @(posedge clock) begin
        if (reset) begin
            lq_valid <= 0;
            sq_valid <= 0;
            sq_addr_ready <= 0;
            sq_reported <= 0;
            sq_committed <= 0; sq_data_ready<=0;
            commit_head<=0; commit_tail<=0; commit_count<=0;
            outstanding_q <= 0;
            result_busy <= 0;
            offer_valid <= 0;
            write_sent <= 0;
            load_rr <= 0; result_rr <= 0;
        end else begin
            case ({req_fire, ld_rsp_valid})
                2'b10: outstanding_q <= outstanding_q + 1'b1;
                2'b01: outstanding_q <= outstanding_q - 1'b1;
                default: begin end
            endcase
            if (chosen_load>=0 && (forward_load || !offer_valid || req_fire))
                load_rr <= chosen_load==LQ_DEPTH-1 ? LIDW'(0) : LIDW'(chosen_load+1);
            if (response_matches) begin
                lq_data[rsp_id] <= load_extend(lq_op[rsp_id], lq_addr[rsp_id][1:0], ld_rsp_payload[31:0]);
                lq_state[rsp_id] <= 3;
            end
            if (offer_valid && squash_valid &&
                (lq_rob[offer_id]-rob_head) > (squash_tag-rob_head)) offer_valid <= 0;
            else if (!offer_valid || req_fire) begin
                offer_valid <= chosen_load >= 0 && !forward_load &&
                    (offer_valid || !req_fire) &&
                    (!squash_valid || RW'(lq_rob[chosen_load]-rob_head)<=RW'(squash_tag-rob_head));
                if (chosen_load >= 0) begin
                    offer_id <= chosen_load;
                    offer_gen <= current_gen;
                    lq_gen[chosen_load] <= current_gen;
                end
            end
            for (int l=0; l<LQ_DEPTH; l=l+1)
                if (load_select[l] && load_forward_valid[l]) begin
                    lq_data[l]<=load_extend(lq_op[l],lq_addr[l][1:0],load_forward_value[l]);
                    lq_state[l]<=3;
                end
            if (result_busy && (result_fire ||
                (squash_valid &&
                 (result_q[RESULT_BITS-1 -: TAG_BITS]-rob_head) > (squash_tag-rob_head)))) begin
                result_busy <= 0;
                if (result_load && result_fire) lq_valid[result_load_id] <= 0;
            end
            begin
                commit_count<=commit_count+SQ_CW'(st_start_valid)-SQ_CW'(write_complete);
                if (st_start_valid) begin
                    commit_fifo[commit_tail]<=st_start_id;
                    commit_tail<=SIDW'((int'(commit_tail)+1)%SQ_DEPTH);
                    sq_committed[st_start_id]<=1;
                    // RAM writes retire once owned by the committed queue.
                    // MMIO remains at ROB head until its external response.
                end
                if (write_complete) begin
                    commit_head<=SIDW'((int'(commit_head)+1)%SQ_DEPTH);
                    sq_committed[active_write_id]<=0;
                end
            end
            if (st_req_valid && st_req_ready) write_sent <= 1;
            if (write_complete) begin
                sq_valid[active_write_id] <= 0;
                    write_sent <= next_write && st_req_valid && st_req_ready;
            end
            for (int st=0; st<SQ_DEPTH; st=st+1)
                    if (sq_valid[st] && sq_addr_ready[st] && !sq_data_ready[st])
                        for (int w=0; w<3; w=w+1)
                            if (forward_valid[w] && forward_pdst[w*PW +: PW]==sq_psrc[st]) begin
                                sq_data[st]<=forward_value[w*32 +: 32]; sq_data_ready[st]<=1;
                            end
            if (exec_valid &&
                (!squash_valid || (exec_rob-rob_head) <= (squash_tag-rob_head))) begin
                if (exec_op >= 5) begin
                    sq_addr[exec_id[SIDW-1:0]] <= exec_addr;
                    sq_data[exec_id[SIDW-1:0]] <= exec_data;
                    sq_data_ready[exec_id[SIDW-1:0]]<=0 || store_data_valid;
                    sq_psrc[exec_id[SIDW-1:0]]<=store_psrc;
                    sq_op[exec_id[SIDW-1:0]] <= exec_op;
                    sq_addr_ready[exec_id[SIDW-1:0]] <= 1;
                end else begin
                    for (int l=0; l<LQ_DEPTH; l=l+1)
                        if (exec_id[LIDW-1:0]==LIDW'(l)) begin
                            lq_addr[l]<=exec_addr;
                            lq_op[l]<=exec_op;
                            if (exec_ram_control[2*l+1]) lq_state[l]<=1;
                            else begin lq_state[l]<=3; lq_data[l]<=0; end
                        end
                end
            end
            if (req_fire) begin
                lq_state[request_id] <= 2;
                lq_gen[request_id] <= request_gen;
            end
            // Current response may bypass ready entries; recovery filters capture.
            if ((!result_busy || result_fire) && chosen_result >= 0 && selected_survives) begin
                // Advance only on consumption or capture, preserving fairness
                // across backpressure. A held result keeps its original identity.
                result_rr <= RESULT_ID_W'((chosen_result+(result_is_store?LQ_DEPTH:0))==RESULT_COUNT-1 ?
                    0 : chosen_result+(result_is_store?LQ_DEPTH:0)+1);
                result_busy <= result_busy || !result_ready;
                result_q <= selected_result;
                if (result_is_store) begin
                    result_load <= 0;
                    sq_reported[chosen_result] <= 1;
                end else begin
                    result_load <= 1;
                    result_load_id <= chosen_result;
                    lq_state[chosen_result] <= 4;
                    if (!result_busy && result_ready)
                        lq_valid[chosen_result] <= 0;
                end
            end
            if (disp_valid && !squash_valid) begin
                    if (disp_lsq[MEM_ALLOC_BITS-1]) begin
                        sq_valid[disp_lsq[PW+TAG_BITS +: MIDW]] <= 1;
                        sq_addr_ready[disp_lsq[PW+TAG_BITS +: MIDW]] <= 0;
                        sq_reported[disp_lsq[PW+TAG_BITS +: MIDW]] <= 0;
                        sq_data_ready[disp_lsq[PW+TAG_BITS +: MIDW]] <= 0;
                        sq_rob[disp_lsq[PW+TAG_BITS +: MIDW]] <=
                            disp_lsq[PW +: TAG_BITS];
                    end else begin
                        lq_valid[disp_lsq[PW+TAG_BITS +: MIDW]] <= 1;
                        lq_state[disp_lsq[PW+TAG_BITS +: MIDW]] <= 0;
                        lq_rob[disp_lsq[PW+TAG_BITS +: MIDW]] <=
                            disp_lsq[PW +: TAG_BITS];
                        lq_pdst[disp_lsq[PW+TAG_BITS +: MIDW]] <=
                            disp_lsq[PW-1:0];
                    end
                end
            if (squash_valid) begin
                for (int l = 0; l < LQ_DEPTH; l = l + 1)
                    if (lq_valid[l] && (lq_rob[l]-rob_head) > (squash_tag-rob_head)) lq_valid[l] <= 0;
                for (int s = 0; s < SQ_DEPTH; s = s + 1)
                    if (sq_valid[s] && !sq_committed[s] && !(st_start_valid && st_start_id==SIDW'(s)) &&
                        (sq_rob[s]-rob_head) > (squash_tag-rob_head)) sq_valid[s] <= 0;
            end
        end
    end
endmodule

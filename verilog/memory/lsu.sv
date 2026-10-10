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
    output logic [LQ_CW-1:0] lq_free,
    output logic [SQ_CW-1:0] sq_free,
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
    reg [SIDW-1:0] sq_commit_ticket [0:SQ_DEPTH-1];
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
    logic load_blocked;
    logic load_executing;
    logic [31:0] candidate_addr;
    logic [2:0] candidate_op;
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
    wire [SIDW-1:0] offer_write_id=next_write ? commit_fifo[SIDW'(commit_head+1'b1)] : active_write_id;
    wire [31:0] write_addr = sq_addr[offer_write_id];
    wire [31:0] write_data = sq_data[offer_write_id];
    wire [2:0] write_op = sq_op[offer_write_id];
    wire [LIDW-1:0] rsp_id = ld_rsp_payload[32 +: LIDW];
    wire [GEN_WIDTH-1:0] rsp_gen = ld_rsp_payload[32+LIDW +: GEN_WIDTH];
    wire request_executing=(read_exec_valid);
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

    always_comb begin
        lq_free = 0;
        sq_free = 0;
        lq_alloc_id = 0;
        sq_alloc_id = 0;
        lq_reserved = 0;
        sq_reserved = 0;
        for (int l = 0; l < LQ_DEPTH; l = l + 1) if (!lq_valid[l]) lq_free = lq_free + 1'b1;
        for (int s = 0; s < SQ_DEPTH; s = s + 1) if (!sq_valid[s]) sq_free = sq_free + 1'b1;
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
    localparam integer LOAD_LEAVES=2**$clog2(LQ_DEPTH);
    localparam integer RESULT_LEAVES=2**$clog2(LQ_DEPTH+SQ_DEPTH);
    reg load_tree_valid [1:2*LOAD_LEAVES-1];
    reg [RW-1:0] load_tree_age [1:2*LOAD_LEAVES-1];
    reg [LIDW-1:0] load_tree_id [1:2*LOAD_LEAVES-1];
    localparam integer STORE_AGE_W=(RW>SIDW)?RW:SIDW;
    reg [LQ_DEPTH-1:0] load_forward_valid;
    reg [SIDW-1:0] load_forward_id [0:LQ_DEPTH-1];
    reg overlapping_store, unknown_store;
    reg [STORE_AGE_W:0] newest_store_age, store_age;
    reg [SIDW-1:0] newest_store;
    reg [3:0] load_mask, store_mask;
    wire forward_load=chosen_load>=0 && load_forward_valid[LIDW'(chosen_load)];
    localparam integer RESULT_ID_W=$clog2(LQ_DEPTH+SQ_DEPTH);
    reg result_tree_valid [1:2*RESULT_LEAVES-1];
    reg [RW-1:0] result_tree_age [1:2*RESULT_LEAVES-1];
    reg [RESULT_ID_W-1:0] result_tree_id [1:2*RESULT_LEAVES-1];
    always_comb begin
        load_forward_valid=0;
        overlapping_store=0; unknown_store=0; newest_store_age=0; store_age=0;
        newest_store=0; load_mask=0; store_mask=0;
        for (int l=0; l<LQ_DEPTH; l=l+1) load_forward_id[l]=0;
        for (int l=0; l<LOAD_LEAVES; l=l+1) begin
            load_tree_valid[LOAD_LEAVES+l]=0;
            load_tree_age[LOAD_LEAVES+l]=0;
            load_tree_id[LOAD_LEAVES+l]=LIDW'(l);
            if (l<LQ_DEPTH) begin
                load_executing=request_executing && exec_op<5 &&
                    exec_id[LIDW-1:0]==LIDW'(l) && lq_state[l]==0 && exec_ram_control[2*l];
                candidate_addr=load_executing?exec_addr:lq_addr[l];
                candidate_op=load_executing?exec_op:lq_op[l];
                load_blocked=0;
                overlapping_store=0; unknown_store=0; newest_store_age=0; newest_store=0;
                load_mask=byte_mask(candidate_op,candidate_addr[1:0]);
                for (int st=0; st<SQ_DEPTH; st=st+1) begin
                    // Committed Stores precede every live ROB entry. Their
                    // FIFO position remains ordered even after ROB tag reuse.
                    store_age={1'b1,STORE_AGE_W'(RW'(sq_rob[st]-rob_head))};
                    if (sq_committed[st]) begin
                        // The FIFO slot is a ticket while this Store remains
                        // committed. Modular distance from its head gives the
                        // rank without searching every FIFO slot for each Load.
                        store_age=STORE_AGE_W'(SIDW'(sq_commit_ticket[st]-commit_head));
                    end
                    if (sq_valid[st] && (sq_committed[st] || RW'(sq_rob[st]-rob_head)<RW'(lq_rob[l]-rob_head))) begin
                        if (!sq_addr_ready[st]) begin load_blocked=1; unknown_store=1; end
                        else if (sq_addr[st][31:2]==candidate_addr[31:2] &&
                            (byte_mask(sq_op[st],sq_addr[st][1:0]) & load_mask)!=0) begin
                            load_blocked=1;
                            if (!overlapping_store || store_age>newest_store_age) begin
                                overlapping_store=1; newest_store_age=store_age; newest_store=SIDW'(st);
                            end
                        end
                    end
                end
                store_mask=byte_mask(sq_op[newest_store],sq_addr[newest_store][1:0]);
                load_forward_valid[l]=lq_state[l]==1 &&
                    overlapping_store && !unknown_store && sq_data_ready[newest_store] &&
                    (store_mask & load_mask)==load_mask && candidate_addr[31:28]==0;
                load_forward_id[l]=newest_store;
                load_tree_valid[LOAD_LEAVES+l]=lq_valid[l] &&
                    (lq_state[l]==1 || load_executing) && (!load_blocked || load_forward_valid[l]) &&
                    !(offer_valid && offer_id==LIDW'(l));
                load_tree_age[LOAD_LEAVES+l]=lq_rob[l]-rob_head;
            end
        end
        for (int n=LOAD_LEAVES-1; n>0; n=n-1) begin
            if (load_tree_valid[2*n] && (!load_tree_valid[2*n+1] ||
                load_tree_age[2*n]<=load_tree_age[2*n+1])) begin
                load_tree_valid[n]=1;
                load_tree_age[n]=load_tree_age[2*n]; load_tree_id[n]=load_tree_id[2*n];
            end else begin
                load_tree_valid[n]=load_tree_valid[2*n+1];
                load_tree_age[n]=load_tree_age[2*n+1]; load_tree_id[n]=load_tree_id[2*n+1];
            end
        end
        chosen_load=load_tree_valid[1]?int'(load_tree_id[1]):-1;
    end
    always_comb begin
        for (int leaf=0; leaf<RESULT_LEAVES; leaf=leaf+1) begin
            result_tree_valid[RESULT_LEAVES+leaf]=0;
            result_tree_age[RESULT_LEAVES+leaf]=0;
            result_tree_id[RESULT_LEAVES+leaf]=RESULT_ID_W'(leaf);
            if (leaf<LQ_DEPTH) begin
                result_tree_valid[RESULT_LEAVES+leaf]=lq_valid[leaf] &&
                    lq_state[leaf]==3;
                result_tree_age[RESULT_LEAVES+leaf]=lq_rob[leaf]-rob_head;
            end else if (leaf<LQ_DEPTH+SQ_DEPTH) begin
                result_tree_valid[RESULT_LEAVES+leaf]=sq_valid[leaf-LQ_DEPTH] &&
                    sq_addr_ready[leaf-LQ_DEPTH] &&
                    sq_data_ready[leaf-LQ_DEPTH] &&
                    !sq_reported[leaf-LQ_DEPTH];
                result_tree_age[RESULT_LEAVES+leaf]=sq_rob[leaf-LQ_DEPTH]-rob_head;
            end
        end
        for (int n=RESULT_LEAVES-1; n>0; n=n-1) begin
            if (result_tree_valid[2*n] && (!result_tree_valid[2*n+1] ||
                result_tree_age[2*n]<=result_tree_age[2*n+1])) begin
                result_tree_valid[n]=1;
                result_tree_age[n]=result_tree_age[2*n]; result_tree_id[n]=result_tree_id[2*n];
            end else begin
                result_tree_valid[n]=result_tree_valid[2*n+1];
                result_tree_age[n]=result_tree_age[2*n+1]; result_tree_id[n]=result_tree_id[2*n+1];
            end
        end
        result_is_store=int'(result_tree_id[1])>=LQ_DEPTH;
        chosen_result=result_tree_valid[1]?
            (result_is_store?int'(result_tree_id[1])-LQ_DEPTH:int'(result_tree_id[1])):-1;
        if (response_matches) begin
            chosen_result=int'(rsp_id); result_is_store=0;
        end
        // Ready queue selection is independent of current response identity.
        // Current response bypasses the queue age tree for every payload field.
        selected_result = 0;
        if (result_tree_valid[1]) begin
            if (int'(result_tree_id[1])>=LQ_DEPTH)
                selected_result={sq_rob[int'(result_tree_id[1])-LQ_DEPTH],{PW{1'b0}},32'b0};
            else
                selected_result={lq_rob[LIDW'(result_tree_id[1])],lq_pdst[LIDW'(result_tree_id[1])],
                    lq_data[LIDW'(result_tree_id[1])]};
        end
        if (response_choice[0]) selected_result[0 +: 16]=response_value[0 +: 16];
        if (response_choice[1]) selected_result[16 +: 16]=response_value[16 +: 16];
        if (response_choice[2]) selected_result[32 +: PW]=response_pdst;
        if (response_choice[3]) selected_result[32+PW +: TAG_BITS]=response_tag;
    end
    assign exec_ready = 1'b1;
    assign result_valid = result_busy ||
        (response_priority || result_tree_valid[1]);
    // Empty-buffer Store completion has no physical destination or value.
    // Keep current Cache selection out of the nonzero forwarding identities.
    assign result_payload = !result_busy ? selected_result : result_q;
    // Offers address RAM only. A read accepted on the squash edge is harmless:
    // its original generation still identifies the later, discarded response.
    // The single-issue path bypasses an empty request buffer. If the cache or
    // read credits stall it, the selected address/gen/id are held from the edge.
    assign ld_req_valid = (offer_valid || (chosen_load >= 0 && !forward_load)) &&
        outstanding_q < LOAD_OUTSTANDING;
    assign ld_req_payload = {request_gen, request_id,
        ((!offer_valid && request_executing && exec_op < 5 &&
          exec_id[LIDW-1:0] == request_id && lq_state[request_id] == 0) ?
         exec_addr : lq_addr[request_id]) & 32'hfffffffc};
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
        end else begin
            case ({req_fire, ld_rsp_valid})
                2'b10: outstanding_q <= outstanding_q + 1'b1;
                2'b01: outstanding_q <= outstanding_q - 1'b1;
                default: begin end
            endcase
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
            if (forward_load) begin
                lq_data[chosen_load]<=load_extend(lq_op[chosen_load],lq_addr[chosen_load][1:0],
                    sq_data[load_forward_id[chosen_load]] << (8*sq_addr[load_forward_id[chosen_load]][1:0]));
                lq_state[chosen_load]<=3;
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
                    sq_commit_ticket[st_start_id]<=commit_tail;
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
            // Prepare completion independently of recovery; never retain a
            // cancelled response. 1 may defer an older ready
            // entry for one cycle when a younger response is cancelled.
            if ((!result_busy || result_fire) && chosen_result >= 0 && selected_survives) begin
                // Empty-buffer bypass consumes the selected result now. With
                // WB backpressure, or when replacing an older buffered result,
                // capture it instead. Unselected responses remain in the LQ.
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

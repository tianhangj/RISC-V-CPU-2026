module lsu #(
    parameter integer PIPELINED = 1,
    parameter integer RESULT_PIPELINED = PIPELINED,
    parameter integer BUFFER_STORES = 0,
    parameter integer EARLY_STORE = 0, EARLY_LOAD = 0, FORWARD_WIDTH=3,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer LOAD_OUTSTANDING = 8,
    parameter integer GEN_WIDTH = 16,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer LQ_CW = $clog2(LQ_DEPTH + 1),
    parameter integer SQ_CW = $clog2(SQ_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer MEM_ALLOC_BITS = 1 + MIDW + TAG_BITS + PW,
    parameter integer MEM_EXEC_BITS = TAG_BITS + 3 + MIDW + 96,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32,
    parameter integer LD_REQ_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer LD_RSP_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer WRITE_REQ_BITS = 68
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [GEN_WIDTH-1:0] current_gen,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] disp_lsq,
    output logic [LQ_CW-1:0] lq_free,
    output logic [SQ_CW-1:0] sq_free,
    output logic [DISPATCH_WIDTH*LIDW-1:0] lq_alloc_id,
    output logic [DISPATCH_WIDTH*SIDW-1:0] sq_alloc_id,
    input wire store_data_valid,
    input wire [PW-1:0] store_psrc,
    input wire [FORWARD_WIDTH-1:0] forward_valid,
    input wire [FORWARD_WIDTH*PW-1:0] forward_pdst,
    input wire [FORWARD_WIDTH*32-1:0] forward_value,
    input logic exec_valid,
    output logic exec_ready,
    input logic [MEM_EXEC_BITS-1:0] exec_payload,
    output wire early_load_valid,
    output wire [PW-1:0] early_load_pdst,
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
    localparam integer OCW = $clog2(LOAD_OUTSTANDING + 1);
    logic [LQ_DEPTH-1:0] lq_valid;
    logic [SQ_DEPTH-1:0] sq_valid, sq_addr_ready, sq_reported;
    logic [SQ_DEPTH-1:0] sq_committed, sq_data_ready;
    reg [PW-1:0] sq_psrc [0:SQ_DEPTH-1];
    reg [SIDW-1:0] commit_fifo [0:SQ_DEPTH-1];
    reg [SIDW-1:0] commit_head, commit_tail;
    reg [SQ_CW-1:0] commit_count;
    reg commit_ack;
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
    logic write_active, write_sent;
    logic [SIDW-1:0] write_id;
    wire [SIDW-1:0] active_write_id = BUFFER_STORES != 0 ? commit_fifo[commit_head] :
        (write_active ? write_id : st_start_id);
    wire write_complete=st_rsp_valid && (BUFFER_STORES != 0 ? commit_count!=0 : write_active);
    wire [TAG_BITS-1:0] exec_rob = exec_payload[MEM_EXEC_BITS-1 -: TAG_BITS];
    wire [2:0] exec_op = exec_payload[96+MIDW +: 3];
    wire [MIDW-1:0] exec_id = exec_payload[96 +: MIDW];
    wire [31:0] exec_addr = exec_payload[95:64] + exec_payload[63:32];
    wire [2*LQ_DEPTH-1:0] exec_ram_control;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2*LQ_DEPTH))
        distribute_exec_ram(exec_addr[31:28]==0,exec_ram_control);
    wire [31:0] exec_data = exec_payload[31:0];
    wire store_executing = exec_valid && exec_op >= 5 &&
        exec_id[SIDW-1:0] == active_write_id;
    wire [31:0] write_addr = store_executing ? exec_addr : sq_addr[active_write_id];
    wire [31:0] write_data = store_executing ? exec_data : sq_data[active_write_id];
    wire [2:0] write_op = store_executing ? exec_op : sq_op[active_write_id];
    wire [LIDW-1:0] rsp_id = ld_rsp_payload[32 +: LIDW];
    wire [GEN_WIDTH-1:0] rsp_gen = ld_rsp_payload[32+LIDW +: GEN_WIDTH];
    wire req_fire = ld_req_valid && ld_req_ready;
    wire result_fire = result_valid && result_ready;
    wire response_matches = ld_rsp_valid && lq_valid[rsp_id] &&
        lq_state[rsp_id] == 2 && lq_gen[rsp_id] == rsp_gen;
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
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            alloc_l = -1;
            alloc_s = -1;
            for (int l = 0; l < LQ_DEPTH; l = l + 1)
                if (alloc_l < 0 && !lq_valid[l] && !lq_reserved[l]) alloc_l = l;
            for (int s = 0; s < SQ_DEPTH; s = s + 1)
                if (alloc_s < 0 && !sq_valid[s] && !sq_reserved[s]) alloc_s = s;
            if (alloc_l >= 0) begin
                lq_alloc_id[lane*LIDW +: LIDW] = alloc_l;
                lq_reserved[alloc_l] = 1;
            end
            if (alloc_s >= 0) begin
                sq_alloc_id[lane*SIDW +: SIDW] = alloc_s;
                sq_reserved[alloc_s] = 1;
            end
        end
    end
    localparam integer LOAD_LEAVES=2**$clog2(LQ_DEPTH);
    localparam integer RESULT_LEAVES=2**$clog2(LQ_DEPTH+SQ_DEPTH);
    reg load_tree_valid [1:2*LOAD_LEAVES-1];
    reg [RW-1:0] load_tree_age [1:2*LOAD_LEAVES-1];
    reg [LIDW-1:0] load_tree_id [1:2*LOAD_LEAVES-1];
    localparam integer RESULT_ID_W=$clog2(LQ_DEPTH+SQ_DEPTH);
    reg result_tree_valid [1:2*RESULT_LEAVES-1];
    reg [RW-1:0] result_tree_age [1:2*RESULT_LEAVES-1];
    reg [RESULT_ID_W-1:0] result_tree_id [1:2*RESULT_LEAVES-1];
    always_comb begin
        for (int l=0; l<LOAD_LEAVES; l=l+1) begin
            load_tree_valid[LOAD_LEAVES+l]=0;
            load_tree_age[LOAD_LEAVES+l]=0;
            load_tree_id[LOAD_LEAVES+l]=LIDW'(l);
            if (l<LQ_DEPTH) begin
                load_executing=exec_valid && exec_op<5 &&
                    exec_id[LIDW-1:0]==LIDW'(l) && lq_state[l]==0 && exec_ram_control[2*l];
                candidate_addr=load_executing?exec_addr:lq_addr[l];
                candidate_op=load_executing?exec_op:lq_op[l];
                load_blocked=0;
                for (int st=0; st<SQ_DEPTH; st=st+1)
                    if (sq_valid[st] && (sq_committed[st] || RW'(sq_rob[st]-rob_head)<RW'(lq_rob[l]-rob_head)) &&
                        (!sq_addr_ready[st] ||
                         (sq_addr[st][31:2]==candidate_addr[31:2] &&
                          (byte_mask(sq_op[st],sq_addr[st][1:0]) &
                           byte_mask(candidate_op,candidate_addr[1:0]))!=0))) load_blocked=1;
                load_tree_valid[LOAD_LEAVES+l]=lq_valid[l] &&
                    (lq_state[l]==1 || load_executing) && !load_blocked &&
                    !(offer_valid && offer_id==LIDW'(l)) &&
                    (!squash_valid || RW'(lq_rob[l]-rob_head)<=RW'(squash_tag-rob_head));
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
        for (int leaf=0; leaf<RESULT_LEAVES; leaf=leaf+1) begin
            result_tree_valid[RESULT_LEAVES+leaf]=0;
            result_tree_age[RESULT_LEAVES+leaf]=0;
            result_tree_id[RESULT_LEAVES+leaf]=RESULT_ID_W'(leaf);
            if (leaf<LQ_DEPTH) begin
                result_tree_valid[RESULT_LEAVES+leaf]=lq_valid[leaf] &&
                    (lq_state[leaf]==3 || (response_matches && rsp_id==LIDW'(leaf)));
                result_tree_age[RESULT_LEAVES+leaf]=lq_rob[leaf]-rob_head;
            end else if (leaf<LQ_DEPTH+SQ_DEPTH) begin
                result_tree_valid[RESULT_LEAVES+leaf]=sq_valid[leaf-LQ_DEPTH] &&
                    (sq_addr_ready[leaf-LQ_DEPTH] ||
                     (exec_valid && exec_op>=5 && exec_id[SIDW-1:0]==SIDW'(leaf-LQ_DEPTH))) &&
                    (EARLY_STORE==0 || sq_data_ready[leaf-LQ_DEPTH] ||
                     (exec_valid && exec_op>=5 && exec_id[SIDW-1:0]==SIDW'(leaf-LQ_DEPTH) && store_data_valid)) &&
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
        selected_result = 0;
        if (chosen_result >= 0) begin
            if (result_is_store)
                selected_result = {sq_rob[chosen_result], {PW{1'b0}}, 32'b0};
            else
                selected_result = {lq_rob[chosen_result], lq_pdst[chosen_result],
                    (response_matches && rsp_id == LIDW'(chosen_result)) ?
                    load_extend(lq_op[chosen_result], lq_addr[chosen_result][1:0],
                        ld_rsp_payload[31:0]) : lq_data[chosen_result]};
        end
    end
    assign early_load_valid=EARLY_LOAD!=0 && (!result_busy || result_ready) &&
        chosen_result>=0 && !result_is_store;
    assign early_load_pdst=selected_result[32 +: PW];
    assign exec_ready = 1'b1;
    assign result_valid = result_busy || (RESULT_PIPELINED == 0 && chosen_result >= 0);
    assign result_payload = (RESULT_PIPELINED == 0 && !result_busy) ? selected_result : result_q;
    // Offers address RAM only. A read accepted on the squash edge is harmless:
    // its original generation still identifies the later, discarded response.
    // The single-issue path bypasses an empty request buffer. If the cache or
    // read credits stall it, the selected address/gen/id are held from the edge.
    assign ld_req_valid = (offer_valid || (PIPELINED == 0 && chosen_load >= 0)) &&
        outstanding_q < LOAD_OUTSTANDING;
    assign ld_req_payload = {request_gen, request_id,
        ((!offer_valid && exec_valid && exec_op < 5 &&
          exec_id[LIDW-1:0] == request_id && lq_state[request_id] == 0) ?
         exec_addr : lq_addr[request_id]) & 32'hfffffffc};
    // ROB authorization already identifies a completed, non-speculative Store.
    // Send it immediately; write_id/write_sent retain the offer if the cache
    // applies backpressure or until its response arrives.
    assign st_req_valid = (BUFFER_STORES != 0 ? commit_count!=0 : (write_active || st_start_valid)) && !write_sent;
    assign st_req_payload = {write_addr & 32'hfffffffc,
        write_data << (8*write_addr[1:0]), byte_mask(write_op, write_addr[1:0])};
    assign st_done_valid = BUFFER_STORES != 0 ?
        (commit_ack || (write_complete && sq_addr[active_write_id][31:28]!=0)) : write_complete;

    always_ff @(posedge clock) begin
        if (reset) begin
            lq_valid <= 0;
            sq_valid <= 0;
            sq_addr_ready <= 0;
            sq_reported <= 0;
            sq_committed <= 0; sq_data_ready<=0;
            commit_head<=0; commit_tail<=0; commit_count<=0; commit_ack<=0;
            outstanding_q <= 0;
            result_busy <= 0;
            offer_valid <= 0;
            write_active <= 0;
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
                offer_valid <= chosen_load >= 0 &&
                    (PIPELINED != 0 || offer_valid || !req_fire);
                if (chosen_load >= 0) begin
                    offer_id <= chosen_load;
                    offer_gen <= current_gen;
                    lq_gen[chosen_load] <= current_gen;
                end
            end
            if (result_busy && (result_fire ||
                (squash_valid &&
                 (result_q[RESULT_BITS-1 -: TAG_BITS]-rob_head) > (squash_tag-rob_head)))) begin
                result_busy <= 0;
                if (result_load && result_fire) lq_valid[result_load_id] <= 0;
            end
            commit_ack<=0;
            if (BUFFER_STORES != 0) begin
                commit_count<=commit_count+SQ_CW'(st_start_valid)-SQ_CW'(write_complete);
                if (st_start_valid) begin
                    commit_fifo[commit_tail]<=st_start_id;
                    commit_tail<=SIDW'((int'(commit_tail)+1)%SQ_DEPTH);
                    sq_committed[st_start_id]<=1;
                    // RAM writes retire once owned by the committed queue.
                    // MMIO remains at ROB head until its external response.
                    commit_ack<=sq_addr[st_start_id][31:28]==0;
                end
                if (write_complete) begin
                    commit_head<=SIDW'((int'(commit_head)+1)%SQ_DEPTH);
                    sq_committed[active_write_id]<=0;
                end
            end else if (st_start_valid) begin
                write_active <= 1;
                write_sent <= 0;
                write_id <= st_start_id;
            end
            if (st_req_valid && st_req_ready) write_sent <= 1;
            if (write_complete) begin
                sq_valid[active_write_id] <= 0;
                write_active <= 0;
                write_sent <= 0;
            end
            if (EARLY_STORE!=0)
                for (int st=0; st<SQ_DEPTH; st=st+1)
                    if (sq_valid[st] && sq_addr_ready[st] && !sq_data_ready[st])
                        for (int w=0; w<FORWARD_WIDTH; w=w+1)
                            if (forward_valid[w] && forward_pdst[w*PW +: PW]==sq_psrc[st]) begin
                                sq_data[st]<=forward_value[w*32 +: 32]; sq_data_ready[st]<=1;
                            end
            if (exec_valid &&
                (!squash_valid || (exec_rob-rob_head) <= (squash_tag-rob_head))) begin
                if (exec_op >= 5) begin
                    sq_addr[exec_id[SIDW-1:0]] <= exec_addr;
                    sq_data[exec_id[SIDW-1:0]] <= exec_data;
                    sq_data_ready[exec_id[SIDW-1:0]]<=EARLY_STORE==0 || store_data_valid;
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
            // The oldest completion is prepared independently of recovery.
            // WB discards a younger same-edge offer; it must never be retained
            // here after squash. If the oldest is young, all other candidates
            // are young too, so filtering once preserves the selection order.
            if ((!result_busy || result_fire) && chosen_result >= 0 && selected_survives) begin
                // Empty-buffer bypass consumes the selected result now. With
                // WB backpressure, or when replacing an older buffered result,
                // capture it instead. Unselected responses remain in the LQ.
                result_busy <= RESULT_PIPELINED != 0 || result_busy || !result_ready;
                result_q <= selected_result;
                if (result_is_store) begin
                    result_load <= 0;
                    sq_reported[chosen_result] <= 1;
                end else begin
                    result_load <= 1;
                    result_load_id <= chosen_result;
                    lq_state[chosen_result] <= 4;
                    if (RESULT_PIPELINED == 0 && !result_busy && result_ready)
                        lq_valid[chosen_result] <= 0;
                end
            end
            for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                if (disp_valid[lane] && !squash_valid) begin
                    if (disp_lsq[lane*MEM_ALLOC_BITS+MEM_ALLOC_BITS-1]) begin
                        sq_valid[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 1;
                        sq_addr_ready[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 0;
                        sq_reported[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 0;
                        sq_data_ready[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 0;
                        sq_rob[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <=
                            disp_lsq[lane*MEM_ALLOC_BITS+PW +: TAG_BITS];
                    end else begin
                        lq_valid[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 1;
                        lq_state[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 0;
                        lq_rob[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <=
                            disp_lsq[lane*MEM_ALLOC_BITS+PW +: TAG_BITS];
                        lq_pdst[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <=
                            disp_lsq[lane*MEM_ALLOC_BITS +: PW];
                    end
                end
            if (squash_valid) begin
                for (int l = 0; l < LQ_DEPTH; l = l + 1)
                    if (lq_valid[l] && (lq_rob[l]-rob_head) > (squash_tag-rob_head)) lq_valid[l] <= 0;
                for (int s = 0; s < SQ_DEPTH; s = s + 1)
                    if (sq_valid[s] && !sq_committed[s] && !(BUFFER_STORES != 0 && st_start_valid && st_start_id==SIDW'(s)) &&
                        (sq_rob[s]-rob_head) > (squash_tag-rob_head)) sq_valid[s] <= 0;
            end
        end
    end
endmodule

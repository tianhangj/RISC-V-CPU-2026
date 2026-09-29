module lsu #(
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
    input logic exec_valid,
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
    localparam integer OCW = $clog2(LOAD_OUTSTANDING + 1);
    logic [LQ_DEPTH-1:0] lq_valid;
    logic [SQ_DEPTH-1:0] sq_valid, sq_addr_ready, sq_reported;
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
    logic [RW-1:0] best_age;
    logic result_is_store;
    logic [RESULT_BITS-1:0] result_q;
    logic result_busy, result_load;
    logic [LIDW-1:0] result_load_id;
    logic offer_valid;
    logic [LIDW-1:0] offer_id;
    logic [GEN_WIDTH-1:0] offer_gen;
    logic write_active, write_sent;
    logic [SIDW-1:0] write_id;
    wire [TAG_BITS-1:0] exec_rob = exec_payload[MEM_EXEC_BITS-1 -: TAG_BITS];
    wire [2:0] exec_op = exec_payload[96+MIDW +: 3];
    wire [MIDW-1:0] exec_id = exec_payload[96 +: MIDW];
    wire [31:0] exec_addr = exec_payload[95:64] + exec_payload[63:32];
    wire [31:0] exec_data = exec_payload[31:0];
    wire [LIDW-1:0] rsp_id = ld_rsp_payload[32 +: LIDW];
    wire [GEN_WIDTH-1:0] rsp_gen = ld_rsp_payload[32+LIDW +: GEN_WIDTH];
    wire req_fire = ld_req_valid && ld_req_ready;
    wire result_fire = result_valid && result_ready;

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
    always_comb begin
        chosen_load = -1;
        best_age = {RW{1'b1}};
        for (int l = 0; l < LQ_DEPTH; l = l + 1) begin
            load_blocked = 0;
            for (int s = 0; s < SQ_DEPTH; s = s + 1)
                if (sq_valid[s] && (sq_rob[s] - rob_head) < (lq_rob[l] - rob_head) &&
                    (!sq_addr_ready[s] ||
                     ((sq_addr[s][31:2] == lq_addr[l][31:2]) &&
                      ((byte_mask(sq_op[s], sq_addr[s][1:0]) &
                        byte_mask(lq_op[l], lq_addr[l][1:0])) != 0)))) load_blocked = 1;
            if (lq_valid[l] && lq_state[l] == 1 && !load_blocked &&
                (!squash_valid || (lq_rob[l]-rob_head) <= (squash_tag-rob_head)) &&
                (chosen_load < 0 || (lq_rob[l]-rob_head) < best_age)) begin
                chosen_load = l;
                best_age = lq_rob[l] - rob_head;
            end
        end
        chosen_result = -1;
        result_is_store = 0;
        best_age = {RW{1'b1}};
        for (int l = 0; l < LQ_DEPTH; l = l + 1)
            if (lq_valid[l] && lq_state[l] == 3 &&
                (!squash_valid || (lq_rob[l]-rob_head) <= (squash_tag-rob_head)) &&
                (chosen_result < 0 || (lq_rob[l]-rob_head) < best_age)) begin
                chosen_result = l;
                result_is_store = 0;
                best_age = lq_rob[l] - rob_head;
            end
        for (int s = 0; s < SQ_DEPTH; s = s + 1)
            if (sq_valid[s] && sq_addr_ready[s] && !sq_reported[s] &&
                (!squash_valid || (sq_rob[s]-rob_head) <= (squash_tag-rob_head)) &&
                (chosen_result < 0 || (sq_rob[s]-rob_head) < best_age)) begin
                chosen_result = s;
                result_is_store = 1;
                best_age = sq_rob[s] - rob_head;
            end
    end
    assign exec_ready = 1'b1;
    assign result_valid = result_busy;
    assign result_payload = result_q;
    assign ld_req_valid = offer_valid && outstanding_q < LOAD_OUTSTANDING &&
        (!squash_valid || (lq_rob[offer_id]-rob_head) <= (squash_tag-rob_head));
    assign ld_req_payload = {offer_gen, offer_id, (lq_addr[offer_id] & 32'hfffffffc)};
    assign st_req_valid = write_active && !write_sent;
    assign st_req_payload = {sq_addr[write_id] & 32'hfffffffc,
        sq_data[write_id] << (8*sq_addr[write_id][1:0]),
        byte_mask(sq_op[write_id], sq_addr[write_id][1:0])};
    assign st_done_valid = st_rsp_valid && write_active;

    always_ff @(posedge clock) begin
        if (reset) begin
            lq_valid <= 0;
            sq_valid <= 0;
            sq_addr_ready <= 0;
            sq_reported <= 0;
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
            if (ld_rsp_valid && lq_valid[rsp_id] && lq_state[rsp_id] == 2 &&
                lq_gen[rsp_id] == rsp_gen &&
                (!squash_valid || (lq_rob[rsp_id]-rob_head) <= (squash_tag-rob_head))) begin
                lq_data[rsp_id] <= load_extend(lq_op[rsp_id], lq_addr[rsp_id][1:0], ld_rsp_payload[31:0]);
                lq_state[rsp_id] <= 3;
            end
            if (offer_valid && squash_valid &&
                (lq_rob[offer_id]-rob_head) > (squash_tag-rob_head)) offer_valid <= 0;
            else if (req_fire) begin
                offer_valid <= 0;
                lq_state[offer_id] <= 2;
            end else if (!offer_valid && chosen_load >= 0) begin
                offer_valid <= 1;
                offer_id <= chosen_load;
                offer_gen <= current_gen;
                lq_gen[chosen_load] <= current_gen;
            end
            if (result_busy && (result_fire ||
                (squash_valid &&
                 (result_q[RESULT_BITS-1 -: TAG_BITS]-rob_head) > (squash_tag-rob_head)))) begin
                result_busy <= 0;
                if (result_load && result_fire) lq_valid[result_load_id] <= 0;
            end
            if (!result_busy && chosen_result >= 0) begin
                result_busy <= 1;
                if (result_is_store) begin
                    result_q <= {sq_rob[chosen_result], {PW{1'b0}}, 32'b0};
                    result_load <= 0;
                    sq_reported[chosen_result] <= 1;
                end else begin
                    result_q <= {lq_rob[chosen_result], lq_pdst[chosen_result], lq_data[chosen_result]};
                    result_load <= 1;
                    result_load_id <= chosen_result;
                    lq_state[chosen_result] <= 4;
                end
            end
            if (st_start_valid) begin
                write_active <= 1;
                write_sent <= 0;
                write_id <= st_start_id;
            end
            if (st_req_valid && st_req_ready) write_sent <= 1;
            if (st_done_valid) begin
                sq_valid[write_id] <= 0;
                write_active <= 0;
            end
            if (exec_valid &&
                (!squash_valid || (exec_rob-rob_head) <= (squash_tag-rob_head))) begin
                if (exec_op >= 5) begin
                    sq_addr[exec_id[SIDW-1:0]] <= exec_addr;
                    sq_data[exec_id[SIDW-1:0]] <= exec_data;
                    sq_op[exec_id[SIDW-1:0]] <= exec_op;
                    sq_addr_ready[exec_id[SIDW-1:0]] <= 1;
                end else begin
                    lq_addr[exec_id[LIDW-1:0]] <= exec_addr;
                    lq_op[exec_id[LIDW-1:0]] <= exec_op;
                    if (exec_addr[31:28] == 0) lq_state[exec_id[LIDW-1:0]] <= 1;
                    else begin
                        lq_state[exec_id[LIDW-1:0]] <= 3;
                        lq_data[exec_id[LIDW-1:0]] <= 0;
                    end
                end
            end
            for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                if (disp_valid[lane] && !squash_valid) begin
                    if (disp_lsq[lane*MEM_ALLOC_BITS+MEM_ALLOC_BITS-1]) begin
                        sq_valid[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 1;
                        sq_addr_ready[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 0;
                        sq_reported[disp_lsq[lane*MEM_ALLOC_BITS+PW+TAG_BITS +: MIDW]] <= 0;
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
                    if (sq_valid[s] && (sq_rob[s]-rob_head) > (squash_tag-rob_head)) sq_valid[s] <= 0;
            end
        end
    end
endmodule

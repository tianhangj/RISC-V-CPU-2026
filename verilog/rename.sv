module rename #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_ALU_DEPTH = 16,
    parameter integer IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer ROB_CW = $clog2(ROB_DEPTH + 1),
    parameter integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1),
    parameter integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1),
    parameter integer LQ_CW = $clog2(LQ_DEPTH + 1),
    parameter integer SQ_CW = $clog2(SQ_DEPTH + 1),
    parameter integer CCW = $clog2(CHECKPOINT_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer DECODE_BITS = 117,
    parameter integer ROB_ALLOC_BITS = PW + 2 + SIDW,
    parameter integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 64,
    parameter integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32,
    parameter integer MEM_ALLOC_BITS = 1 + MIDW + TAG_BITS + PW,
    parameter integer CP_ALLOC_BITS = CIDW + TAG_BITS + 32,
    parameter integer REG_COMMIT_BITS = PW
) (
    input logic clock, reset, squash_valid,
    input logic [CIDW-1:0] restore_cp_id,
    input logic [CHECKPOINT_DEPTH-1:0] cp_release_mask,
    input logic [CCW-1:0] cp_free,
    input logic [DISPATCH_WIDTH*CIDW-1:0] cp_alloc_id,
    input logic decode_valid,
    output logic decode_ready,
    input logic [DCW-1:0] decode_count,
    input logic [DISPATCH_WIDTH*DECODE_BITS-1:0] decode_uop,
    input logic [ROB_CW-1:0] rob_free,
    input logic [RW-1:0] rob_tail,
    input logic [AIQ_CW-1:0] alu_iq_free,
    input logic [MIQ_CW-1:0] mem_iq_free,
    input logic [LQ_CW-1:0] lq_free,
    input logic [SQ_CW-1:0] sq_free,
    input logic [DISPATCH_WIDTH*LIDW-1:0] lq_alloc_id,
    input logic [DISPATCH_WIDTH*SIDW-1:0] sq_alloc_id,
    output logic disp_valid,
    input logic disp_ready,
    output logic [DCW-1:0] disp_count,
    output logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] disp_rob,
    output logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] disp_alu,
    output logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_mem,
    output logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] disp_lsq,
    output logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready,
    output logic [DISPATCH_WIDTH-1:0] cp_alloc_valid,
    output logic [DISPATCH_WIDTH*CP_ALLOC_BITS-1:0] cp_alloc_payload,
    output logic front_redirect_valid,
    output logic [31:0] front_redirect_pc,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    input logic [COMMIT_WIDTH-1:0] reg_commit_valid,
    input logic [COMMIT_WIDTH*REG_COMMIT_BITS-1:0] reg_commit_payload
);
    logic [PW-1:0] rat [0:31];
    logic [PRF_SIZE-1:0] free_q, ready_q;
    logic [PW-1:0] snapshot [0:CHECKPOINT_DEPTH-1][0:31];
    logic [PRF_SIZE-1:0] younger_alloc [0:CHECKPOINT_DEPTH-1];
    logic [CHECKPOINT_DEPTH-1:0] snapshot_valid;
    logic buf_valid, offer_valid, offer_front;
    logic [DCW-1:0] buf_count, offer_count;
    logic [DECODE_BITS-1:0] buffer_uop [0:DISPATCH_WIDTH-1];
    wire [DISPATCH_WIDTH*DECODE_BITS-1:0] buffer_flat;
    wire [32*PW-1:0] rat_flat;
    for (genvar lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin : g_flat_buffer
        assign buffer_flat[lane*DECODE_BITS +: DECODE_BITS] = buffer_uop[lane];
    end
    for (genvar regno = 0; regno < 32; regno = regno + 1) begin : g_flat_rat
        assign rat_flat[regno*PW +: PW] = rat[regno];
    end
    logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] offer_rob;
    logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] offer_alu;
    logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] offer_mem;
    logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] offer_lsq;
    logic [DISPATCH_WIDTH*CP_ALLOC_BITS-1:0] offer_cp;
    logic [31:0] offer_front_pc;
    logic [DISPATCH_WIDTH-1:0] offer_branch;
    logic [4:0] offer_rd [0:DISPATCH_WIDTH-1];
    logic [PW-1:0] offer_pdst [0:DISPATCH_WIDTH-1];
    logic [PW-1:0] offer_ps1 [0:DISPATCH_WIDTH-1], offer_ps2 [0:DISPATCH_WIDTH-1];
    logic [CIDW-1:0] offer_cp_id [0:DISPATCH_WIDTH-1];
    logic [DCW-1:0] proposed_count;
    logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] proposed_rob;
    logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] proposed_alu;
    logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] proposed_mem;
    logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] proposed_lsq;
    logic [DISPATCH_WIDTH*CP_ALLOC_BITS-1:0] proposed_cp;
    logic proposed_front;
    logic [31:0] proposed_front_pc;
    logic [DISPATCH_WIDTH-1:0] proposed_branch;
    logic [4:0] proposed_rd [0:DISPATCH_WIDTH-1];
    logic [PW-1:0] proposed_pdst [0:DISPATCH_WIDTH-1];
    logic [PW-1:0] proposed_ps1 [0:DISPATCH_WIDTH-1], proposed_ps2 [0:DISPATCH_WIDTH-1];
    logic [CIDW-1:0] proposed_cp_id [0:DISPATCH_WIDTH-1];
    logic [PW-1:0] rat_tmp [0:31], rat_work [0:31];
    logic [PRF_SIZE-1:0] free_tmp, free_work, ready_work;
    logic [PRF_SIZE-1:0] young_work [0:CHECKPOINT_DEPTH-1];
    logic [CHECKPOINT_DEPTH-1:0] valid_work;
    logic [DECODE_BITS-1:0] dec;
    logic [31:0] pc, pred_npc, imm;
    logic [5:0] op;
    logic [4:0] rs1, rs2, rd;
    logic [PW-1:0] ps1, ps2, pdst, old_pdst;
    logic [RW-1:0] tag;
    logic [MIDW-1:0] mem_id;
    logic [SIDW-1:0] sq_id;
    logic [CIDW-1:0] cp_id;
    logic [1:0] kind;
    logic fit, stop_offer, is_branch, is_load, is_store, source1_ready, source2_ready;
    integer free_pdst, used_alu, used_mem, used_lq, used_sq, used_cp;

    assign decode_ready = !buf_valid && !offer_valid && !squash_valid;
    assign disp_valid = offer_valid && !squash_valid;
    assign disp_count = offer_count;
    assign disp_rob = offer_rob;
    assign disp_alu = offer_alu;
    assign disp_mem = offer_mem;
    assign disp_lsq = offer_lsq;
    assign cp_alloc_payload = offer_cp;
    assign front_redirect_valid = disp_valid && disp_ready && offer_front;
    assign front_redirect_pc = offer_front_pc;

    always_comb begin
        cp_alloc_valid = 0;
        disp_src1_ready = 0;
        disp_src2_ready = 0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            cp_alloc_valid[lane] = disp_valid && disp_ready && lane < offer_count && offer_branch[lane];
            source1_ready = (offer_ps1[lane] == 0) || ready_q[offer_ps1[lane]];
            source2_ready = (offer_ps2[lane] == 0) || ready_q[offer_ps2[lane]];
            for (int w = 0; w < WB_WIDTH; w = w + 1) begin
                if (wake_valid[w] && offer_ps1[lane] == wake_pdst[w*PW +: PW]) source1_ready = 1;
                if (wake_valid[w] && offer_ps2[lane] == wake_pdst[w*PW +: PW]) source2_ready = 1;
            end
            for (int older = 0; older < DISPATCH_WIDTH; older = older + 1)
                if (older < lane && offer_pdst[older] != 0) begin
                    if (offer_ps1[lane] == offer_pdst[older]) source1_ready = 0;
                    if (offer_ps2[lane] == offer_pdst[older]) source2_ready = 0;
                end
            disp_src1_ready[lane] = source1_ready;
            disp_src2_ready[lane] = source2_ready;
        end
    end

    always @(buffer_flat or rat_flat or free_q or buf_count or rob_free or rob_tail or
             alu_iq_free or mem_iq_free or lq_free or sq_free or cp_free or
             lq_alloc_id or sq_alloc_id or cp_alloc_id) begin
        for (int r = 0; r < 32; r = r + 1) rat_tmp[r] = rat[r];
        free_tmp = free_q;
        proposed_count = 0;
        proposed_rob = 0;
        proposed_alu = 0;
        proposed_mem = 0;
        proposed_lsq = 0;
        proposed_cp = 0;
        proposed_branch = 0;
        proposed_front = 0;
        proposed_front_pc = 0;
        used_alu = 0; used_mem = 0; used_lq = 0; used_sq = 0; used_cp = 0;
        stop_offer = 0;
        tag = '0;
        ps1 = '0;
        ps2 = '0;
        pdst = '0;
        old_pdst = '0;
        mem_id = '0;
        sq_id = '0;
        cp_id = '0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            proposed_rd[lane] = 0;
            proposed_pdst[lane] = 0;
            proposed_ps1[lane] = 0;
            proposed_ps2[lane] = 0;
            proposed_cp_id[lane] = 0;
            dec = buffer_uop[lane];
            pc = dec[DECODE_BITS-1 -: 32];
            pred_npc = dec[DECODE_BITS-33 -: 32];
            op = dec[52:47];
            rs1 = dec[46:42];
            rs2 = dec[41:37];
            rd = dec[36:32];
            imm = dec[31:0];
            is_branch = op >= 3 && op <= 10;
            is_load = op >= 30 && op <= 34;
            is_store = op >= 35 && op <= 37;
            kind = is_branch ? 2'd1 : is_load ? 2'd2 : is_store ? 2'd3 : 2'd0;
            free_pdst = -1;
            for (int p = 1; p < PRF_SIZE; p = p + 1)
                if (free_pdst < 0 && free_tmp[p]) free_pdst = p;
            fit = !stop_offer && lane < buf_count && lane < rob_free &&
                (rd == 0 || free_pdst >= 0) &&
                (is_branch ? used_cp < cp_free : 1'b1) &&
                ((is_load || is_store) ? used_mem < mem_iq_free : used_alu < alu_iq_free) &&
                (is_load ? used_lq < lq_free : 1'b1) &&
                (is_store ? used_sq < sq_free : 1'b1);
            if (fit) begin
                tag = rob_tail + lane;
                ps1 = rat_tmp[rs1];
                ps2 = rat_tmp[rs2];
                pdst = (rd == 0) ? 0 : free_pdst;
                old_pdst = (rd == 0) ? 0 : rat_tmp[rd];
                if (rd != 0) begin
                    rat_tmp[rd] = pdst;
                    free_tmp[pdst] = 0;
                end
                mem_id = 0; sq_id = 0; cp_id = 0;
                if (is_load) begin mem_id = lq_alloc_id[used_lq*LIDW +: LIDW]; used_lq = used_lq + 1; end
                if (is_store) begin
                    mem_id = sq_alloc_id[used_sq*SIDW +: SIDW];
                    sq_id = mem_id[SIDW-1:0];
                    used_sq = used_sq + 1;
                end
                if (is_branch) begin
                    cp_id = cp_alloc_id[used_cp*CIDW +: CIDW];
                    used_cp = used_cp + 1;
                end
                if (is_load || is_store) used_mem = used_mem + 1;
                else used_alu = used_alu + 1;
                proposed_count = proposed_count + 1'b1;
                proposed_rd[lane] = rd;
                proposed_pdst[lane] = pdst;
                proposed_ps1[lane] = ps1;
                proposed_ps2[lane] = ps2;
                proposed_cp_id[lane] = cp_id;
                proposed_branch[lane] = is_branch;
                proposed_rob[lane*ROB_ALLOC_BITS +: ROB_ALLOC_BITS] = {old_pdst, kind, sq_id};
                proposed_alu[lane*ALU_IQ_BITS +: ALU_IQ_BITS] =
                    {tag, cp_id, op, pdst, ps1, ps2, pc, imm};
                proposed_mem[lane*MEM_IQ_BITS +: MEM_IQ_BITS] =
                    {tag, (op[2:0] - 3'd6), mem_id, ps1, ps2, imm};
                proposed_lsq[lane*MEM_ALLOC_BITS +: MEM_ALLOC_BITS] =
                    {is_store, mem_id, tag, pdst};
                proposed_cp[lane*CP_ALLOC_BITS +: CP_ALLOC_BITS] = {cp_id, tag, pred_npc};
                if (!is_branch && pred_npc != pc + 32'd4) begin
                    proposed_front = 1;
                    proposed_front_pc = pc + 32'd4;
                    stop_offer = 1;
                end
            end else stop_offer = 1;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            buf_valid <= 0;
            offer_valid <= 0;
            snapshot_valid <= 0;
            for (int r = 0; r < 32; r = r + 1) rat[r] <= r;
            for (int p = 0; p < PRF_SIZE; p = p + 1) begin
                free_q[p] <= (p >= 32);
                ready_q[p] <= (p < 32);
            end
        end else begin
            for (int r = 0; r < 32; r = r + 1) rat_work[r] = rat[r];
            free_work = free_q;
            ready_work = ready_q;
            valid_work = snapshot_valid;
            for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
                young_work[c] = younger_alloc[c];
            for (int w = 0; w < WB_WIDTH; w = w + 1)
                if (wake_valid[w] && wake_pdst[w*PW +: PW] != 0)
                    ready_work[wake_pdst[w*PW +: PW]] = 1;
            for (int c = 0; c < COMMIT_WIDTH; c = c + 1)
                if (reg_commit_valid[c] && reg_commit_payload[c*PW +: PW] != 0)
                    free_work[reg_commit_payload[c*PW +: PW]] = 1;
            if (squash_valid) begin
                for (int r = 1; r < 32; r = r + 1)
                    rat_work[r] = snapshot[restore_cp_id][r];
                free_work = free_work | younger_alloc[restore_cp_id];
                ready_work = ready_work & ~younger_alloc[restore_cp_id];
                buf_valid <= 0;
                offer_valid <= 0;
            end else begin
                if (decode_valid && decode_ready) begin
                    buf_valid <= 1;
                    buf_count <= decode_count;
                    for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                        buffer_uop[lane] <= decode_uop[lane*DECODE_BITS +: DECODE_BITS];
                end
                if (buf_valid && !offer_valid && proposed_count != 0) begin
                    offer_valid <= 1;
                    offer_count <= proposed_count;
                    offer_rob <= proposed_rob;
                    offer_alu <= proposed_alu;
                    offer_mem <= proposed_mem;
                    offer_lsq <= proposed_lsq;
                    offer_cp <= proposed_cp;
                    offer_branch <= proposed_branch;
                    offer_front <= proposed_front;
                    offer_front_pc <= proposed_front_pc;
                    for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
                        offer_rd[lane] <= proposed_rd[lane];
                        offer_pdst[lane] <= proposed_pdst[lane];
                        offer_ps1[lane] <= proposed_ps1[lane];
                        offer_ps2[lane] <= proposed_ps2[lane];
                        offer_cp_id[lane] <= proposed_cp_id[lane];
                    end
                end
                if (disp_valid && disp_ready) begin
                    offer_valid <= 0;
                    if (offer_front || offer_count == buf_count) buf_valid <= 0;
                    else begin
                        buf_count <= buf_count - offer_count;
                        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                            if (lane + offer_count < DISPATCH_WIDTH)
                                buffer_uop[lane] <= buffer_uop[lane + offer_count];
                    end
                    for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
                        if (lane < offer_count) begin
                            if (offer_pdst[lane] != 0) begin
                                rat_work[offer_rd[lane]] = offer_pdst[lane];
                                free_work[offer_pdst[lane]] = 0;
                                ready_work[offer_pdst[lane]] = 0;
                                for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
                                    if (valid_work[c]) young_work[c][offer_pdst[lane]] = 1;
                            end
                            if (offer_branch[lane]) begin
                                valid_work[offer_cp_id[lane]] = 1;
                                young_work[offer_cp_id[lane]] = 0;
                                for (int r = 1; r < 32; r = r + 1)
                                    snapshot[offer_cp_id[lane]][r] <= rat_work[r];
                            end
                        end
                    end
                end
            end
            for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
                if (cp_release_mask[c]) valid_work[c] = 0;
            for (int r = 1; r < 32; r = r + 1) rat[r] <= rat_work[r];
            free_q <= free_work;
            ready_q <= ready_work;
            snapshot_valid <= valid_work;
            for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
                younger_alloc[c] <= young_work[c];
        end
    end
endmodule

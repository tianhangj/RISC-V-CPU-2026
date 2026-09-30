module student_top #(
    parameter integer ISSUE_WIDTH = 1,
    parameter integer DISPATCH_WIDTH = 1,
    parameter integer WB_WIDTH = 1,
    parameter integer COMMIT_WIDTH = 1,
    
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_ALU_DEPTH = 16,
    parameter integer IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer LOAD_OUTSTANDING = 8,
    parameter integer AXI_RD_OUTSTANDING = 16,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer GEN_WIDTH = 16,
    parameter [31:0] RESET_PC = 32'h00000000
) (
    input logic clock, reset,
    output logic [31:0] araddr,
    output logic arvalid,
    input logic arready,
    input logic [31:0] rdata,
    input logic [1:0] rresp,
    input logic rvalid,
    output logic rready,
    output logic [31:0] awaddr,
    output logic awvalid,
    input logic awready,
    output logic [31:0] wdata,
    output logic [3:0] wstrb,
    output logic wvalid,
    input logic wready,
    input logic [1:0] bresp,
    input logic bvalid,
    output logic bready
);
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1;
    localparam integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1;
    localparam integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1;
    localparam integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1;
    localparam integer MIDW = (LIDW > SIDW) ? LIDW : SIDW;
    localparam integer DCW = $clog2(DISPATCH_WIDTH + 1);
    localparam integer ROB_CW = $clog2(ROB_DEPTH + 1);
    localparam integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1);
    localparam integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1);
    localparam integer LQ_CW = $clog2(LQ_DEPTH + 1);
    localparam integer SQ_CW = $clog2(SQ_DEPTH + 1);
    localparam integer CCW = $clog2(CHECKPOINT_DEPTH + 1);
    localparam integer FETCH_BITS = 96;
    localparam integer DECODE_BITS = 117;
    localparam integer ROB_ALLOC_BITS = PW + 2 + SIDW;
    localparam integer ALU_IQ_BITS = RW + CIDW + 6 + 3*PW + 64;
    localparam integer MEM_IQ_BITS = RW + 3 + MIDW + 2*PW + 32;
    localparam integer MEM_ALLOC_BITS = 1 + MIDW + RW + PW;
    localparam integer CP_ALLOC_BITS = CIDW + RW + 32;
    localparam integer ALU_EXEC_BITS = RW + CIDW + 6 + PW + 128;
    localparam integer MUL_EXEC_BITS = RW + 3 + PW + 64;
    localparam integer MEM_EXEC_BITS = RW + 3 + MIDW + 96;
    localparam integer RESULT_BITS = RW + PW + 32;
    localparam integer RESOLVE_BITS = RW + CIDW + 32;
    localparam integer IF_REQ_BITS = GEN_WIDTH + FIDW + 32;
    localparam integer LD_REQ_BITS = GEN_WIDTH + LIDW + 32;
    localparam integer WRITE_REQ_BITS = 68;

    logic if_req_valid, if_req_ready, if_rsp_valid;
    logic [IF_REQ_BITS-1:0] if_req_payload, if_rsp_payload;
    logic ld_req_valid, ld_req_ready, ld_rsp_valid;
    logic [LD_REQ_BITS-1:0] ld_req_payload, ld_rsp_payload;
    logic st_req_valid, st_req_ready, st_rsp_valid;
    logic [WRITE_REQ_BITS-1:0] st_req_payload;
    logic fetch_valid, fetch_ready, decode_valid, decode_ready;
    logic [DCW-1:0] fetch_count, decode_count;
    logic [DISPATCH_WIDTH*FETCH_BITS-1:0] fetch_packet;
    logic [DISPATCH_WIDTH*DECODE_BITS-1:0] decode_uop;
    logic [GEN_WIDTH-1:0] current_gen;
    logic [CCW-1:0] cp_free;
    logic [DISPATCH_WIDTH*CIDW-1:0] cp_alloc_id;
    logic [DISPATCH_WIDTH-1:0] cp_alloc_valid;
    logic [DISPATCH_WIDTH*CP_ALLOC_BITS-1:0] cp_alloc_payload;
    logic [CHECKPOINT_DEPTH-1:0] cp_release_mask;
    logic squash_valid, fetch_redirect_valid, front_redirect_valid;
    logic [RW-1:0] squash_tag, rob_head, rob_tail;
    logic [CIDW-1:0] restore_cp_id;
    logic [32+GEN_WIDTH-1:0] fetch_redirect_payload;
    logic [31:0] front_redirect_pc;
    logic disp_valid, disp_ready, disp_fire;
    logic [DCW-1:0] disp_count;
    logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] disp_rob;
    logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] disp_alu;
    logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_mem;
    logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] disp_lsq;
    logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready;
    logic [DISPATCH_WIDTH-1:0] alu_disp_valid, mem_disp_valid;
    logic [ROB_CW-1:0] rob_free;
    logic [AIQ_CW-1:0] alu_iq_free;
    logic [MIQ_CW-1:0] mem_iq_free;
    logic [LQ_CW-1:0] lq_free;
    logic [SQ_CW-1:0] sq_free;
    logic [DISPATCH_WIDTH*LIDW-1:0] lq_alloc_id;
    logic [DISPATCH_WIDTH*SIDW-1:0] sq_alloc_id;
    logic [COMMIT_WIDTH-1:0] reg_commit_valid;
    logic [COMMIT_WIDTH*PW-1:0] reg_commit_payload;
    logic st_start_valid, st_done_valid;
    logic [SIDW-1:0] st_start_id;
    logic [ISSUE_WIDTH-1:0] alu_cand_valid, alu_cand_take;
    logic mem_cand_valid, mem_cand_take;
    logic [ISSUE_WIDTH*ALU_IQ_BITS-1:0] alu_cand_uop;
    logic [MEM_IQ_BITS-1:0] mem_cand_uop;
    logic [2*ISSUE_WIDTH*PW-1:0] rd_addr;
    logic [2*ISSUE_WIDTH*32-1:0] rd_data;
    logic [ISSUE_WIDTH-1:0] alu_exec_valid, alu_exec_ready;
    logic [ISSUE_WIDTH*ALU_EXEC_BITS-1:0] alu_exec_payload;
    logic mul_exec_valid, mul_exec_ready, mem_exec_valid, mem_exec_ready;
    logic [MUL_EXEC_BITS-1:0] mul_exec_payload;
    logic [MEM_EXEC_BITS-1:0] mem_exec_payload;
    logic [ISSUE_WIDTH-1:0] alu_result_valid, alu_result_ready, resolve_valid;
    logic [ISSUE_WIDTH*RESULT_BITS-1:0] alu_result_payload;
    logic [ISSUE_WIDTH*RESOLVE_BITS-1:0] resolve_payload;
    logic mul_result_valid, mul_result_ready, lsu_result_valid, lsu_result_ready;
    logic [RESULT_BITS-1:0] mul_result_payload, lsu_result_payload;
    logic [WB_WIDTH-1:0] done_valid, write_valid;
    logic [WB_WIDTH*RW-1:0] done_tag;
    logic [WB_WIDTH*PW-1:0] write_pdst;
    logic [WB_WIDTH*32-1:0] write_value;
    integer need_alu, need_mem, need_lq, need_sq;
    logic [1:0] lane_kind;

    always @(disp_rob or disp_count or disp_fire or squash_valid or rob_free or
             alu_iq_free or mem_iq_free or lq_free or sq_free) begin
        need_alu = 0; need_mem = 0; need_lq = 0; need_sq = 0;
        alu_disp_valid = 0;
        mem_disp_valid = 0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            lane_kind = disp_rob[lane*ROB_ALLOC_BITS+SIDW +: 2];
            if (lane < disp_count) begin
                if (lane_kind == 2 || lane_kind == 3) begin
                    need_mem = need_mem + 1;
                    if (lane_kind == 2) need_lq = need_lq + 1;
                    else need_sq = need_sq + 1;
                end else need_alu = need_alu + 1;
            end
            if (disp_fire && lane < disp_count) begin
                alu_disp_valid[lane] = !(lane_kind == 2 || lane_kind == 3);
                mem_disp_valid[lane] = (lane_kind == 2 || lane_kind == 3);
            end
        end
        disp_ready = !squash_valid && rob_free >= disp_count &&
            alu_iq_free >= need_alu && mem_iq_free >= need_mem &&
            lq_free >= need_lq && sq_free >= need_sq;
    end
    assign disp_fire = disp_valid && disp_ready;

    fetch #(.DISPATCH_WIDTH(DISPATCH_WIDTH), .FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH),
        .IFETCH_OUTSTANDING(IFETCH_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH),
        .RESET_PC(RESET_PC)) u_fetch (
        .clock, .reset, .fetch_redirect_valid, .fetch_redirect_payload,
        .if_req_valid, .if_req_ready, .if_req_payload, .if_rsp_valid, .if_rsp_payload,
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet);
    decode #(.DISPATCH_WIDTH(DISPATCH_WIDTH)) u_decode (
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet,
        .decode_valid, .decode_ready, .decode_count, .decode_uop);
    rename #(.DISPATCH_WIDTH(DISPATCH_WIDTH), .WB_WIDTH(WB_WIDTH),
        .COMMIT_WIDTH(COMMIT_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .IQ_ALU_DEPTH(IQ_ALU_DEPTH), .IQ_MEM_DEPTH(IQ_MEM_DEPTH),
        .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_rename (
        .clock, .reset, .squash_valid, .restore_cp_id, .cp_release_mask,
        .cp_free, .cp_alloc_id, .decode_valid, .decode_ready, .decode_count, .decode_uop,
        .rob_free, .rob_tail, .alu_iq_free, .mem_iq_free, .lq_free, .sq_free,
        .lq_alloc_id, .sq_alloc_id, .disp_valid, .disp_ready, .disp_count,
        .disp_rob, .disp_alu, .disp_mem, .disp_lsq,
        .disp_src1_ready, .disp_src2_ready, .cp_alloc_valid, .cp_alloc_payload,
        .front_redirect_valid, .front_redirect_pc,
        .wake_valid(write_valid), .wake_pdst(write_pdst),
        .reg_commit_valid, .reg_commit_payload);
    rob #(.DISPATCH_WIDTH(DISPATCH_WIDTH), .WB_WIDTH(WB_WIDTH),
        .COMMIT_WIDTH(COMMIT_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .SQ_DEPTH(SQ_DEPTH)) u_rob (
        .clock, .reset, .squash_valid, .squash_tag,
        .disp_fire, .disp_count, .disp_rob, .done_valid, .done_tag,
        .rob_free, .rob_tail, .rob_head, .reg_commit_valid, .reg_commit_payload,
        .st_start_valid, .st_start_id, .st_done_valid);
    branch_ctrl #(.ISSUE_WIDTH(ISSUE_WIDTH), .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .ROB_DEPTH(ROB_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH),
        .GEN_WIDTH(GEN_WIDTH)) u_branch (
        .clock, .reset, .rob_head, .current_gen, .cp_free, .cp_alloc_id,
        .cp_alloc_valid, .cp_alloc_payload, .front_redirect_valid, .front_redirect_pc,
        .resolve_valid, .resolve_payload, .cp_release_mask,
        .squash_valid, .squash_tag, .restore_cp_id,
        .fetch_redirect_valid, .fetch_redirect_payload);
    iq_alu #(.ISSUE_WIDTH(ISSUE_WIDTH), .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .WB_WIDTH(WB_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .IQ_ALU_DEPTH(IQ_ALU_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_iq_alu (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .disp_valid(alu_disp_valid), .disp_uop(disp_alu),
        .disp_src1_ready, .disp_src2_ready, .wake_valid(write_valid), .wake_pdst(write_pdst),
        .alu_iq_free, .cand_valid(alu_cand_valid), .cand_uop(alu_cand_uop),
        .cand_take(alu_cand_take));
    iq_mem #(.DISPATCH_WIDTH(DISPATCH_WIDTH),
        .WB_WIDTH(WB_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .IQ_MEM_DEPTH(IQ_MEM_DEPTH), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH)) u_iq_mem (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .disp_valid(mem_disp_valid), .disp_uop(disp_mem),
        .disp_src1_ready, .disp_src2_ready, .wake_valid(write_valid), .wake_pdst(write_pdst),
        .mem_iq_free, .cand_valid(mem_cand_valid), .cand_uop(mem_cand_uop),
        .cand_take(mem_cand_take));
    issue_sched #(.ISSUE_WIDTH(ISSUE_WIDTH), .ROB_DEPTH(ROB_DEPTH),
        .PRF_SIZE(PRF_SIZE), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH),
        .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_issue (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .alu_cand_valid, .alu_cand_uop, .alu_cand_take,
        .mem_cand_valid, .mem_cand_uop, .mem_cand_take,
        .rd_addr, .rd_data, .alu_exec_valid, .alu_exec_ready, .alu_exec_payload,
        .mul_exec_valid, .mul_exec_ready, .mul_exec_payload,
        .mem_exec_valid, .mem_exec_ready, .mem_exec_payload);
    prf #(.ISSUE_WIDTH(ISSUE_WIDTH), .WB_WIDTH(WB_WIDTH), .PRF_SIZE(PRF_SIZE)) u_prf (
        .clock, .reset, .rd_addr, .rd_data, .write_valid, .write_pdst, .write_value);
    for (genvar lane = 0; lane < ISSUE_WIDTH; lane = lane + 1) begin : g_alu
        alu #(.ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
            .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_alu (
            .clock, .reset, .squash_valid, .squash_tag, .rob_head,
            .exec_valid(alu_exec_valid[lane]), .exec_ready(alu_exec_ready[lane]),
            .exec_payload(alu_exec_payload[lane*ALU_EXEC_BITS +: ALU_EXEC_BITS]),
            .result_valid(alu_result_valid[lane]), .result_ready(alu_result_ready[lane]),
            .result_payload(alu_result_payload[lane*RESULT_BITS +: RESULT_BITS]),
            .resolve_valid(resolve_valid[lane]),
            .resolve_payload(resolve_payload[lane*RESOLVE_BITS +: RESOLVE_BITS]));
    end
    mul_div #(.ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE)) u_mul_div (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .exec_valid(mul_exec_valid), .exec_ready(mul_exec_ready), .exec_payload(mul_exec_payload),
        .result_valid(mul_result_valid), .result_ready(mul_result_ready),
        .result_payload(mul_result_payload));
    lsu #(.DISPATCH_WIDTH(DISPATCH_WIDTH), .ROB_DEPTH(ROB_DEPTH),
        .PRF_SIZE(PRF_SIZE), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH),
        .LOAD_OUTSTANDING(LOAD_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH)) u_lsu (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head, .current_gen,
        .disp_valid(mem_disp_valid), .disp_lsq, .lq_free, .sq_free,
        .lq_alloc_id, .sq_alloc_id,
        .exec_valid(mem_exec_valid), .exec_ready(mem_exec_ready), .exec_payload(mem_exec_payload),
        .result_valid(lsu_result_valid), .result_ready(lsu_result_ready),
        .result_payload(lsu_result_payload),
        .st_start_valid, .st_start_id, .st_done_valid,
        .ld_req_valid, .ld_req_ready, .ld_req_payload, .ld_rsp_valid, .ld_rsp_payload,
        .st_req_valid, .st_req_ready, .st_req_payload, .st_rsp_valid);
    wb_arb #(.ISSUE_WIDTH(ISSUE_WIDTH), .WB_WIDTH(WB_WIDTH),
        .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE)) u_wb (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .alu_result_valid, .alu_result_ready, .alu_result_payload,
        .mul_result_valid, .mul_result_ready, .mul_result_payload,
        .lsu_result_valid, .lsu_result_ready, .lsu_result_payload,
        .done_valid, .done_tag, .write_valid, .write_pdst, .write_value);
    axi_bridge #(.LQ_DEPTH(LQ_DEPTH), .FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH),
        .AXI_RD_OUTSTANDING(AXI_RD_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH)) u_axi (
        .clock, .reset, .if_req_valid, .if_req_ready, .if_req_payload,
        .if_rsp_valid, .if_rsp_payload, .ld_req_valid, .ld_req_ready, .ld_req_payload,
        .ld_rsp_valid, .ld_rsp_payload, .st_req_valid, .st_req_ready, .st_req_payload,
        .st_rsp_valid, .araddr, .arvalid, .arready, .rdata, .rresp, .rvalid,
        .rready, .awaddr, .awvalid, .awready, .wdata, .wstrb, .wvalid,
        .wready, .bresp, .bvalid, .bready);
endmodule

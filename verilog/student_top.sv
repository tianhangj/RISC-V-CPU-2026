module student_top #(
    parameter integer ISSUE_WIDTH = 1,
    parameter integer DISPATCH_WIDTH = 1,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_ALU_DEPTH = 7,
    parameter integer IQ_MEM_DEPTH = 4,
    parameter integer LQ_DEPTH = 4,
    parameter integer SQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer ICACHE_SIZE_BYTES = 1024,
    parameter integer ICACHE_WAYS = 2,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer DCACHE_SIZE_BYTES = 16384,
    parameter integer DCACHE_WAYS = 2,
    parameter integer DCACHE_LINE_BYTES = 64,
    parameter integer DATA_PREFETCH = 1,
    parameter integer BP_ENABLE = 1,
    parameter integer BTB_ENTRIES = 32,
    parameter integer BHT_ENTRIES = 256,
    parameter integer LOAD_OUTSTANDING = 4,
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
    localparam integer RESOLVE_BITS = RW + CIDW + 98;
    localparam integer BP_TRAIN_BITS = 66;
    localparam integer IF_ID_WIDTH = $clog2(ICACHE_LINE_BYTES/4);
    localparam integer IF_REQ_BITS = GEN_WIDTH + IF_ID_WIDTH + 32;
    localparam integer IC_REQ_BITS = GEN_WIDTH + FIDW + DCW + 32;
    localparam integer IC_RSP_BITS = GEN_WIDTH + FIDW + DCW + 32*DISPATCH_WIDTH;
    localparam integer LD_REQ_BITS = GEN_WIDTH + LIDW + 32;
    localparam integer WRITE_REQ_BITS = 68;
    localparam integer DC_WORD_W = $clog2(DCACHE_LINE_BYTES/4);
    localparam integer MEM_LD_BITS = GEN_WIDTH + DC_WORD_W + 32;
    wire mem_ld_req_valid, mem_ld_req_ready, mem_ld_rsp_valid;
    wire line_req_valid, line_req_ready, line_rsp_valid;
    wire [DCACHE_LINE_BYTES*8-1:0] line_rsp_data;
    wire [MEM_LD_BITS-1:0] mem_ld_req_payload, mem_ld_rsp_payload;
    localparam integer PREFETCH_ID_BITS=DATA_PREFETCH!=0?2:0;
    localparam integer AXI_LD_BITS=MEM_LD_BITS+PREFETCH_ID_BITS;
    wire axi_ld_req_valid, axi_ld_req_ready, axi_ld_rsp_valid;
    wire [AXI_LD_BITS-1:0] axi_ld_req_payload, axi_ld_rsp_payload;
    wire mem_st_req_valid, mem_st_req_ready, mem_st_rsp_valid;
    wire [67:0] mem_st_req_payload;

    logic if_req_valid, if_req_ready, if_rsp_valid;
    logic [IF_REQ_BITS-1:0] if_req_payload, if_rsp_payload;
    logic ic_req_valid, ic_req_ready, ic_rsp_valid;
    logic [IC_REQ_BITS-1:0] ic_req_payload;
    logic [IC_RSP_BITS-1:0] ic_rsp_payload;
    (* keep *) logic ld_req_valid, ld_req_ready, ld_rsp_valid;
    logic [LD_REQ_BITS-1:0] ld_req_payload, ld_rsp_payload;
    (* keep *) logic st_req_valid, st_req_ready, st_rsp_valid;
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
    (* keep *) logic squash_valid, fetch_redirect_valid, front_redirect_valid;
    logic [RW-1:0] squash_tag, rob_head, rob_tail;
    logic [CIDW-1:0] restore_cp_id;
    logic [32+GEN_WIDTH-1:0] fetch_redirect_payload;
    logic [31:0] front_redirect_pc;
    (* keep *) logic disp_valid, disp_ready, disp_fire;
    logic [DCW-1:0] disp_count;
    logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] disp_rob;
    logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] disp_alu;
    logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_mem;
    logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] disp_lsq;
    logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready;
    logic [DISPATCH_WIDTH-1:0] alu_disp_valid, mem_disp_valid;
    logic [DISPATCH_WIDTH-1:0] alu_disp_prepare, mem_disp_prepare;
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
    logic mem_cand_valid, mem_cand_take, mem_cand_src2_ready;
    wire [31:0] branch_operand1, branch_operand2;
    wire mem_store_data_valid;
    wire [PW-1:0] mem_store_psrc;
    logic [ISSUE_WIDTH*ALU_IQ_BITS-1:0] alu_cand_uop;
    logic [MEM_IQ_BITS-1:0] mem_cand_uop;
    logic [2*ISSUE_WIDTH*PW-1:0] rd_addr;
    logic [2*ISSUE_WIDTH*32-1:0] rd_data;
    logic [ISSUE_WIDTH-1:0] alu_exec_valid, alu_exec_ready;
    logic [ISSUE_WIDTH*ALU_EXEC_BITS-1:0] alu_exec_payload;
    logic mul_exec_valid, mul_exec_ready, mem_exec_valid, mem_exec_ready;
    wire mem_exec_preview_valid;
    logic [MUL_EXEC_BITS-1:0] mul_exec_payload;
    logic [MEM_EXEC_BITS-1:0] mem_exec_payload;
    logic [ISSUE_WIDTH-1:0] alu_result_valid, alu_result_ready, resolve_valid;
    logic [ISSUE_WIDTH*RESULT_BITS-1:0] alu_result_payload;
    logic [ISSUE_WIDTH*RESOLVE_BITS-1:0] resolve_payload;
    wire [31:0] lookup_pc;
    wire [DISPATCH_WIDTH-1:0] pred_taken;
    wire [DISPATCH_WIDTH*32-1:0] pred_npc;
    wire [ISSUE_WIDTH-1:0] train_valid;
    wire [ISSUE_WIDTH*BP_TRAIN_BITS-1:0] train_payload;
    logic mul_result_valid, mul_result_ready, lsu_result_valid, lsu_result_ready;
    logic [RESULT_BITS-1:0] mul_result_payload, lsu_result_payload;
    logic [WB_WIDTH-1:0] done_valid, write_valid;
    logic [WB_WIDTH*RW-1:0] done_tag;
    logic [WB_WIDTH*PW-1:0] write_pdst;
    logic [WB_WIDTH*32-1:0] write_value;
    localparam integer COMPLETION_WIDTH = ISSUE_WIDTH+2;
    wire [COMPLETION_WIDTH-1:0] completion_valid =
        {lsu_result_valid, mul_result_valid, alu_result_valid};
    wire [COMPLETION_WIDTH*RESULT_BITS-1:0] completion_payload =
        {lsu_result_payload, mul_result_payload, alu_result_payload};
    wire [COMPLETION_WIDTH*PW-1:0] completion_pdst;
    wire [COMPLETION_WIDTH*32-1:0] completion_value;
    for (genvar source = 0; source < COMPLETION_WIDTH; source = source+1) begin : g_completion
        assign completion_pdst[source*PW +: PW] = completion_payload[source*RESULT_BITS+32 +: PW];
        assign completion_value[source*32 +: 32] = completion_payload[source*RESULT_BITS +: 32];
    end
    wire early_wake_valid, branch_exec_valid, early_load_valid;
    wire [PW-1:0] early_load_pdst;
    wire [PW-1:0] early_wake_pdst;
    localparam integer IQ_WAKE_WIDTH=COMPLETION_WIDTH+2;
    wire [IQ_WAKE_WIDTH-1:0] iq_wake_valid={early_load_valid,early_wake_valid,completion_valid};
    wire [IQ_WAKE_WIDTH*PW-1:0] iq_wake_pdst={early_load_pdst,early_wake_pdst,completion_pdst};
    wire [(ISSUE_WIDTH+7)*RW-1:0] distributed_head;
    wire [(ISSUE_WIDTH+9)*(RW+1)-1:0] distributed_squash;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(RW), .BRANCHES(ISSUE_WIDTH+7))
        distribute_head(rob_head, distributed_head);
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(RW+1), .BRANCHES(ISSUE_WIDTH+9))
        distribute_recovery({squash_valid, squash_tag}, distributed_squash);
    integer need_alu, need_mem, need_lq, need_sq;
    logic [1:0] lane_kind;

    always @(disp_rob or disp_count or disp_fire or distributed_squash or rob_free or
             alu_iq_free or mem_iq_free or lq_free or sq_free) begin
        need_alu = 0; need_mem = 0; need_lq = 0; need_sq = 0;
        alu_disp_valid = 0;
        mem_disp_valid = 0;
        alu_disp_prepare = 0;
        mem_disp_prepare = 0;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            lane_kind = disp_rob[lane*ROB_ALLOC_BITS+SIDW +: 2];
            if (lane < disp_count) begin
                alu_disp_prepare[lane] = !(lane_kind == 2 || lane_kind == 3);
                mem_disp_prepare[lane] = (lane_kind == 2 || lane_kind == 3);
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
        disp_ready = !distributed_squash[8*(RW+1)+RW] && rob_free >= disp_count &&
            alu_iq_free >= need_alu && mem_iq_free >= need_mem &&
            lq_free >= need_lq && sq_free >= need_sq;
    end
    assign disp_fire = disp_valid && disp_ready;

    branch_predictor #(.DISPATCH_WIDTH(DISPATCH_WIDTH), .ISSUE_WIDTH(ISSUE_WIDTH),
        .BP_ENABLE(BP_ENABLE), .BTB_ENTRIES(BTB_ENTRIES), .BHT_ENTRIES(BHT_ENTRIES), .HISTORY_BITS(8), .GLOBAL_HISTORY(1), .BTB_RAM(1)) u_predictor (
        .clock, .reset, .lookup_pc, .pred_taken, .pred_npc, .train_valid, .train_payload);
    fetch #(.DISPATCH_WIDTH(DISPATCH_WIDTH), .OUTPUT_BYPASS(ISSUE_WIDTH==1), .FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH),
        .IFETCH_OUTSTANDING(IFETCH_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH),
        .RESET_PC(RESET_PC), .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES)) u_fetch (
        .clock, .reset, .fetch_redirect_valid, .fetch_redirect_payload,
        .lookup_pc, .pred_taken, .pred_npc,
        .ic_req_valid, .ic_req_ready, .ic_req_payload, .ic_rsp_valid, .ic_rsp_payload,
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet);
    icache #(.DISPATCH_WIDTH(DISPATCH_WIDTH), .FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH),
        .ICACHE_SIZE_BYTES(ICACHE_SIZE_BYTES), .ICACHE_WAYS(ICACHE_WAYS),
        .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES), .GEN_WIDTH(GEN_WIDTH)) u_icache (
        .clock, .reset, .fetch_redirect_valid,
        .ic_req_valid, .ic_req_ready, .ic_req_payload, .ic_rsp_valid, .ic_rsp_payload,
        .if_req_valid, .if_req_ready, .if_req_payload, .if_rsp_valid, .if_rsp_payload);
    generate if (DISPATCH_WIDTH==1) begin : g_single_decode
    decode #(.DISPATCH_WIDTH(DISPATCH_WIDTH)) u_decode (
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet,
        .decode_valid, .decode_ready, .decode_count, .decode_uop);
    end else begin : g_wide_decode
    decode_pipe #(.DISPATCH_WIDTH(DISPATCH_WIDTH)) u_decode (
        .clock, .reset, .fetch_redirect_valid,
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet,
        .decode_valid, .decode_ready, .decode_count, .decode_uop);
    end endgenerate
    rename #(.DIRECT_RENAME(ISSUE_WIDTH==1), .CHECKPOINT_RAM(ISSUE_WIDTH==1), .CHECKPOINT_BANKED(ISSUE_WIDTH==1), .DISPATCH_WIDTH(DISPATCH_WIDTH), .WB_WIDTH(COMPLETION_WIDTH),
        .COMMIT_WIDTH(COMMIT_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .IQ_ALU_DEPTH(IQ_ALU_DEPTH), .IQ_MEM_DEPTH(IQ_MEM_DEPTH),
        .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_rename (
        .clock, .reset, .squash_valid(distributed_squash[(0)*(RW+1)+RW]), .restore_cp_id, .cp_release_mask,
        .cp_free, .cp_alloc_id, .decode_valid, .decode_ready, .decode_count, .decode_uop,
        .rob_free, .rob_tail, .alu_iq_free, .mem_iq_free, .lq_free, .sq_free,
        .lq_alloc_id, .sq_alloc_id, .disp_valid, .disp_ready, .disp_count,
        .disp_rob, .disp_alu, .disp_mem, .disp_lsq,
        .disp_src1_ready, .disp_src2_ready, .cp_alloc_valid, .cp_alloc_payload,
        .front_redirect_valid, .front_redirect_pc,
        .wake_valid(completion_valid), .wake_pdst(completion_pdst),
        .reg_commit_valid, .reg_commit_payload);
    rob #(.DISPATCH_WIDTH(DISPATCH_WIDTH), .WB_WIDTH(WB_WIDTH),
        .EARLY_STORE_COMMIT(1),
        .COMMIT_WIDTH(COMMIT_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .SQ_DEPTH(SQ_DEPTH)) u_rob (
        .clock, .reset, .squash_valid(distributed_squash[(1)*(RW+1)+RW]), .squash_tag(distributed_squash[(1)*(RW+1) +: RW]),
        .disp_fire, .disp_count, .disp_rob, .done_valid, .done_tag,
        .rob_free, .rob_tail, .rob_head, .reg_commit_valid, .reg_commit_payload,
        .st_start_valid, .st_start_id, .st_done_valid);
    branch_ctrl #(.ISSUE_WIDTH(ISSUE_WIDTH), .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .ROB_DEPTH(ROB_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH),
        .GEN_WIDTH(GEN_WIDTH)) u_branch (
        .clock, .reset, .rob_head(distributed_head[(0)*RW +: RW]), .current_gen, .cp_free, .cp_alloc_id,
        .cp_alloc_valid, .cp_alloc_payload, .front_redirect_valid, .front_redirect_pc,
        .resolve_valid, .resolve_payload, .cp_release_mask,
        .train_valid, .train_payload,
        .squash_valid, .squash_tag, .restore_cp_id,
        .fetch_redirect_valid, .fetch_redirect_payload);
    iq_alu #(.ORDERED_SELECT(ISSUE_WIDTH==1), .PIPELINED(0), .ISSUE_WIDTH(ISSUE_WIDTH), .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .WB_WIDTH(IQ_WAKE_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .IQ_ALU_DEPTH(IQ_ALU_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_iq_alu (
        .clock, .reset, .squash_valid(distributed_squash[(2)*(RW+1)+RW]), .squash_tag(distributed_squash[(2)*(RW+1) +: RW]), .rob_head(distributed_head[(1)*RW +: RW]),
        .disp_valid(alu_disp_valid), .disp_prepare(alu_disp_prepare), .disp_uop(disp_alu),
        .disp_src1_ready, .disp_src2_ready, .wake_valid(iq_wake_valid), .wake_pdst(iq_wake_pdst),
        .alu_iq_free, .cand_valid(alu_cand_valid), .cand_uop(alu_cand_uop),
        .cand_take(alu_cand_take));
    iq_mem #(.ORDERED_SELECT(ISSUE_WIDTH==1), .PIPELINED(0), .EARLY_STORE(ISSUE_WIDTH==1), .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .WB_WIDTH(IQ_WAKE_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .IQ_MEM_DEPTH(IQ_MEM_DEPTH), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH)) u_iq_mem (
        .clock, .reset, .squash_valid(distributed_squash[(3)*(RW+1)+RW]), .squash_tag(distributed_squash[(3)*(RW+1) +: RW]), .rob_head(distributed_head[(2)*RW +: RW]),
        .disp_valid(mem_disp_valid), .disp_prepare(mem_disp_prepare), .disp_uop(disp_mem),
        .disp_src1_ready, .disp_src2_ready, .wake_valid(iq_wake_valid), .wake_pdst(iq_wake_pdst),
        .mem_iq_free, .cand_valid(mem_cand_valid), .cand_src2_ready(mem_cand_src2_ready), .cand_uop(mem_cand_uop),
        .cand_take(mem_cand_take));
    generate if (ISSUE_WIDTH==1) begin : g_single_issue
    single_issue #(.ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
        .EARLY_BRANCH(1), .DELAYED_FORWARD(1), .REGISTERED_LOAD_BRANCH(1), .SNAPSHOT_LOAD_FORWARD(1),
        .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH),
        .FORWARD_WIDTH(COMPLETION_WIDTH)) u_issue (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .alu_cand_valid, .alu_cand_uop, .alu_cand_take,
        .mem_cand_valid, .mem_cand_src2_ready, .mem_cand_uop, .mem_cand_take, .rd_addr, .rd_data,
        .mem_store_data_valid, .mem_store_psrc,
        .forward_valid(completion_valid), .forward_pdst(completion_pdst), .forward_value(completion_value),
        .early_wake_valid, .early_wake_pdst, .branch_exec_valid, .branch_operand1, .branch_operand2,
        .alu_exec_valid, .alu_exec_ready, .alu_exec_payload,
        .mul_exec_valid, .mul_exec_ready, .mul_exec_payload,
        .mem_exec_valid, .mem_exec_preview_valid, .mem_exec_ready, .mem_exec_payload);
    end else begin : g_wide_issue
    assign mem_store_data_valid=1;
    assign mem_store_psrc=0;
    assign branch_exec_valid=0;
    assign mem_exec_preview_valid=0;
    assign branch_operand1=0; assign branch_operand2=0;
    assign early_wake_valid=0;
    assign early_wake_pdst=0;
    issue_sched #(.ISSUE_WIDTH(ISSUE_WIDTH), .ROB_DEPTH(ROB_DEPTH),
        .PRF_SIZE(PRF_SIZE), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH),
        .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_issue (
        .clock, .reset, .squash_valid(distributed_squash[(4)*(RW+1)+RW]), .squash_tag(distributed_squash[(4)*(RW+1) +: RW]), .rob_head(distributed_head[(3)*RW +: RW]),
        .alu_cand_valid, .alu_cand_uop, .alu_cand_take,
        .mem_cand_valid, .mem_cand_uop, .mem_cand_take,
        .rd_addr, .rd_data, .alu_exec_valid, .alu_exec_ready, .alu_exec_payload,
        .mul_exec_valid, .mul_exec_ready, .mul_exec_payload,
        .mem_exec_valid, .mem_exec_ready, .mem_exec_payload);
    end endgenerate
    prf #(.WORD_RAM(1), .BYPASS_WRITE(ISSUE_WIDTH!=1), .ISSUE_WIDTH(ISSUE_WIDTH), .WB_WIDTH(WB_WIDTH),
        .FORWARD_WIDTH(COMPLETION_WIDTH), .PRF_SIZE(PRF_SIZE)) u_prf (
        .clock, .reset, .rd_addr, .rd_data, .write_valid, .write_pdst, .write_value,
        .forward_valid(completion_valid), .forward_pdst(completion_pdst), .forward_value(completion_value));
    for (genvar lane = 0; lane < ISSUE_WIDTH; lane = lane + 1) begin : g_alu
        alu #(.PIPELINED(1), .EARLY_RESOLVE(ISSUE_WIDTH==1), .BRANCH_ISOLATE(ISSUE_WIDTH==1), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE),
            .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_alu (
            .clock, .reset, .squash_valid(distributed_squash[(9+lane)*(RW+1)+RW]), .squash_tag(distributed_squash[(9+lane)*(RW+1) +: RW]), .rob_head(distributed_head[(7+lane)*RW +: RW]),
            .exec_valid(alu_exec_valid[lane]), .resolve_exec_valid(branch_exec_valid), .branch_operand1, .branch_operand2, .exec_ready(alu_exec_ready[lane]),
            .exec_payload(alu_exec_payload[lane*ALU_EXEC_BITS +: ALU_EXEC_BITS]),
            .result_valid(alu_result_valid[lane]), .result_ready(alu_result_ready[lane]),
            .result_payload(alu_result_payload[lane*RESULT_BITS +: RESULT_BITS]),
            .resolve_valid(resolve_valid[lane]),
            .resolve_payload(resolve_payload[lane*RESOLVE_BITS +: RESOLVE_BITS]));
    end
    mul_div #(.ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE)) u_mul_div (
        .clock, .reset, .squash_valid(distributed_squash[(5)*(RW+1)+RW]), .squash_tag(distributed_squash[(5)*(RW+1) +: RW]), .rob_head(distributed_head[(4)*RW +: RW]),
        .exec_valid(mul_exec_valid), .exec_ready(mul_exec_ready), .exec_payload(mul_exec_payload),
        .result_valid(mul_result_valid), .result_ready(mul_result_ready),
        .result_payload(mul_result_payload));
    lsu #(.BYPASS_STORE_RESULTS(1), .SPEC_READ_PREVIEW(ISSUE_WIDTH==1), .EARLY_STORE_COMMIT(1), .PIPELINED(0), .RESULT_PIPELINED(0), .REGISTER_STORE_RESULT(1), .STORE_LOOKAHEAD(1), .RESPONSE_FIRST(1), .STORE_FORWARD(1), .BUFFER_STORES(1), .EARLY_STORE(ISSUE_WIDTH==1), .EARLY_LOAD(0), .FORWARD_WIDTH(COMPLETION_WIDTH), .DISPATCH_WIDTH(DISPATCH_WIDTH), .ROB_DEPTH(ROB_DEPTH),
        .PRF_SIZE(PRF_SIZE), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH),
        .LOAD_OUTSTANDING(LOAD_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH)) u_lsu (
        .clock, .reset, .squash_valid(distributed_squash[(6)*(RW+1)+RW]), .squash_tag(distributed_squash[(6)*(RW+1) +: RW]), .rob_head(distributed_head[(5)*RW +: RW]), .current_gen,
        .disp_valid(mem_disp_valid), .disp_lsq, .lq_free, .sq_free,
        .lq_alloc_id, .sq_alloc_id,
        .exec_valid(mem_exec_valid), .read_exec_valid(mem_exec_preview_valid), .exec_ready(mem_exec_ready), .exec_payload(mem_exec_payload),
        .store_data_valid(mem_store_data_valid), .store_psrc(mem_store_psrc),
        .early_load_valid, .early_load_pdst,
        .forward_valid(completion_valid), .forward_pdst(completion_pdst), .forward_value(completion_value),
        .result_valid(lsu_result_valid), .result_ready(lsu_result_ready),
        .result_payload(lsu_result_payload),
        .st_start_valid, .st_start_id, .st_done_valid,
        .ld_req_valid, .ld_req_ready, .ld_req_payload, .ld_rsp_valid, .ld_rsp_payload,
        .st_req_valid, .st_req_ready, .st_req_payload, .st_rsp_valid);
    wb_arb #(.DEDICATED_ALU(ISSUE_WIDTH==1), .PIPELINED(0), .FILTER_AFTER_SELECT(1), .ISSUE_WIDTH(ISSUE_WIDTH), .WB_WIDTH(WB_WIDTH),
        .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE)) u_wb (
        .clock, .reset, .squash_valid(distributed_squash[(7)*(RW+1)+RW]), .squash_tag(distributed_squash[(7)*(RW+1) +: RW]), .rob_head(distributed_head[(6)*RW +: RW]),
        .alu_result_valid, .alu_result_ready, .alu_result_payload,
        .mul_result_valid, .mul_result_ready, .mul_result_payload,
        .lsu_result_valid, .lsu_result_ready, .lsu_result_payload,
        .done_valid, .done_tag, .write_valid, .write_pdst, .write_value);
    dcache #(.STORE_PIPELINE(1), .HIT_UNDER_MISS(1), .REFILL_HITS(1), .BULK_REFILL(DATA_PREFETCH), .SIZE_BYTES(DCACHE_SIZE_BYTES), .WAYS(DCACHE_WAYS), .LINE_BYTES(DCACHE_LINE_BYTES),
        .LQ_DEPTH(LQ_DEPTH), .GEN_WIDTH(GEN_WIDTH)) u_dcache (
        .clock, .reset, .ld_req_valid, .ld_req_ready, .ld_req_payload,
        .ld_rsp_valid, .ld_rsp_payload, .st_req_valid, .st_req_ready,
        .st_req_payload, .st_rsp_valid,
        .mem_ld_req_valid, .mem_ld_req_ready, .mem_ld_req_payload,
        .mem_ld_rsp_valid, .mem_ld_rsp_payload, .mem_st_req_valid,
        .mem_st_req_ready, .mem_st_req_payload, .mem_st_rsp_valid,
        .line_req_valid, .line_req_ready, .line_rsp_valid, .line_rsp_data);
    generate if (DATA_PREFETCH!=0) begin : g_prefetch
    data_prefetch #(.TARGETED_INVALIDATE(1), .LINE_BYTES(DCACHE_LINE_BYTES), .GEN_WIDTH(GEN_WIDTH)) prefetch (
        .clock, .reset, .dc_req_valid(mem_ld_req_valid), .dc_req_ready(mem_ld_req_ready),
        .dc_req_payload(mem_ld_req_payload), .dc_rsp_valid(mem_ld_rsp_valid), .dc_rsp_payload(mem_ld_rsp_payload),
        .mem_req_valid(axi_ld_req_valid), .mem_req_ready(axi_ld_req_ready), .mem_req_payload(axi_ld_req_payload),
        .mem_rsp_valid(axi_ld_rsp_valid), .mem_rsp_payload(axi_ld_rsp_payload),
        .write_fire(mem_st_req_valid && mem_st_req_ready), .write_addr(mem_st_req_payload[67:36]),
        .line_req_valid, .line_req_ready, .line_rsp_valid, .line_rsp_data);
    end else begin : g_no_prefetch
        assign line_req_ready=0; assign line_rsp_valid=0; assign line_rsp_data=0;
        assign axi_ld_req_valid=mem_ld_req_valid;
        assign axi_ld_req_payload=mem_ld_req_payload;
        assign mem_ld_req_ready=axi_ld_req_ready;
        assign mem_ld_rsp_valid=axi_ld_rsp_valid;
        assign mem_ld_rsp_payload=axi_ld_rsp_payload;
    end endgenerate
    axi_bridge #(.LQ_DEPTH((DCACHE_LINE_BYTES/4)*(DATA_PREFETCH!=0?4:1)), .FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH),
        .AXI_RD_OUTSTANDING(AXI_RD_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH),
        .IF_ID_WIDTH(IF_ID_WIDTH)) u_axi (
        .clock, .reset, .if_req_valid, .if_req_ready, .if_req_payload,
        .if_rsp_valid, .if_rsp_payload,
        .ld_req_valid(axi_ld_req_valid), .ld_req_ready(axi_ld_req_ready),
        .ld_req_payload(axi_ld_req_payload), .ld_rsp_valid(axi_ld_rsp_valid),
        .ld_rsp_payload(axi_ld_rsp_payload), .st_req_valid(mem_st_req_valid),
        .st_req_ready(mem_st_req_ready), .st_req_payload(mem_st_req_payload),
        .st_rsp_valid(mem_st_rsp_valid), .araddr, .arvalid, .arready, .rdata, .rresp, .rvalid,
        .rready, .awaddr, .awvalid, .awready, .wdata, .wstrb, .wvalid,
        .wready, .bresp, .bvalid, .bready);
endmodule

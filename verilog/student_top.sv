module student_top #(
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 56,
    parameter integer IQ_ALU_DEPTH = 7,
    parameter integer IQ_MEM_DEPTH = 4,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer ICACHE_SIZE_BYTES = 2048,
    parameter integer ICACHE_WAYS = 2,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer DCACHE_SIZE_BYTES = 16384,
    parameter integer DCACHE_WAYS = 2,
    parameter integer DCACHE_LINE_BYTES = 64,
    parameter integer DATA_PREFETCH = 1,
    parameter integer BP_ENABLE = 1,
    parameter integer BTB_ENTRIES = 64,
    parameter integer BHT_ENTRIES = 256,
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

    // Reject unsupported configurations during elaboration; valid configurations add no cells.
    if (WB_WIDTH < 1 || WB_WIDTH > 3) begin : g_invalid_0
        initial $fatal(1, "WB_WIDTH must be 1, 2 or 3");
    end
    if (ROB_DEPTH < 2 || (ROB_DEPTH & (ROB_DEPTH-1)) != 0) begin : g_invalid_1
        initial $fatal(1, "ROB_DEPTH must be a power of two >= 2");
    end
    if (COMMIT_WIDTH < 1 || COMMIT_WIDTH > ROB_DEPTH) begin : g_invalid_2
        initial $fatal(1, "COMMIT_WIDTH must be in 1..ROB_DEPTH");
    end
    if (PRF_SIZE <= 32) begin : g_invalid_3
        initial $fatal(1, "PRF_SIZE must exceed 32");
    end
    if (IQ_ALU_DEPTH < 1 || IQ_MEM_DEPTH < 1 || LQ_DEPTH < 1 || CHECKPOINT_DEPTH < 1) begin : g_invalid_4
        initial $fatal(1, "IQ, LQ and checkpoint capacities must be positive");
    end
    if (SQ_DEPTH < 2 || (SQ_DEPTH & (SQ_DEPTH-1)) != 0) begin : g_invalid_5
        initial $fatal(1, "SQ_DEPTH must be a power of two >= 2");
    end
    if (FETCH_QUEUE_DEPTH < 2 || (FETCH_QUEUE_DEPTH & (FETCH_QUEUE_DEPTH-1)) != 0) begin : g_invalid_6
        initial $fatal(1, "FETCH_QUEUE_DEPTH must be a power of two >= 2");
    end
    if (IFETCH_OUTSTANDING < 1 || IFETCH_OUTSTANDING > FETCH_QUEUE_DEPTH || LOAD_OUTSTANDING < 1 || AXI_RD_OUTSTANDING < 1) begin : g_invalid_7
        initial $fatal(1, "invalid outstanding transaction capacity");
    end
    if (GEN_WIDTH < 1 || RESET_PC[1:0] != 0) begin : g_invalid_8
        initial $fatal(1, "GEN_WIDTH must be positive and RESET_PC word aligned");
    end
    if ((BP_ENABLE != 0 && BP_ENABLE != 1) || (DATA_PREFETCH != 0 && DATA_PREFETCH != 1)) begin : g_invalid_9
        initial $fatal(1, "BP_ENABLE and DATA_PREFETCH must be 0 or 1");
    end
    if (BTB_ENTRIES < 2 || BTB_ENTRIES > 536870912 || (BTB_ENTRIES & (BTB_ENTRIES-1)) != 0 || BHT_ENTRIES < 2 || BHT_ENTRIES > 1073741824 || (BHT_ENTRIES & (BHT_ENTRIES-1)) != 0) begin : g_invalid_10
        initial $fatal(1, "prediction tables must be powers of two within address index limits");
    end
    if (ICACHE_WAYS != 1 && ICACHE_WAYS != 2 && ICACHE_WAYS != 4) begin : g_invalid_11
        initial $fatal(1, "ICACHE_WAYS must be 1, 2 or 4");
    end
    if (ICACHE_LINE_BYTES < 16 || ICACHE_LINE_BYTES > 512 || (ICACHE_LINE_BYTES & (ICACHE_LINE_BYTES-1)) != 0) begin : g_invalid_12
        initial $fatal(1, "ICACHE_LINE_BYTES must be a power of two in 16..512");
    end
    if (ICACHE_SIZE_BYTES < ICACHE_WAYS*ICACHE_LINE_BYTES || ICACHE_SIZE_BYTES % (ICACHE_WAYS*ICACHE_LINE_BYTES) != 0 || ((ICACHE_SIZE_BYTES/(ICACHE_WAYS*ICACHE_LINE_BYTES)) & ((ICACHE_SIZE_BYTES/(ICACHE_WAYS*ICACHE_LINE_BYTES))-1)) != 0) begin : g_invalid_13
        initial $fatal(1, "ICACHE_SIZE_BYTES must contain a positive power-of-two number of sets");
    end
    if (DCACHE_WAYS != 1 && DCACHE_WAYS != 2 && DCACHE_WAYS != 4) begin : g_invalid_14
        initial $fatal(1, "DCACHE_WAYS must be 1, 2 or 4");
    end
    if (DCACHE_LINE_BYTES < 16 || DCACHE_LINE_BYTES > 512 || (DCACHE_LINE_BYTES & (DCACHE_LINE_BYTES-1)) != 0) begin : g_invalid_15
        initial $fatal(1, "DCACHE_LINE_BYTES must be a power of two in 16..512");
    end
    if (DCACHE_SIZE_BYTES < DCACHE_WAYS*DCACHE_LINE_BYTES || DCACHE_SIZE_BYTES % (DCACHE_WAYS*DCACHE_LINE_BYTES) != 0 || ((DCACHE_SIZE_BYTES/(DCACHE_WAYS*DCACHE_LINE_BYTES)) & ((DCACHE_SIZE_BYTES/(DCACHE_WAYS*DCACHE_LINE_BYTES))-1)) != 0) begin : g_invalid_16
        initial $fatal(1, "DCACHE_SIZE_BYTES must contain a positive power-of-two number of sets");
    end

    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1;
    localparam integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1;
    localparam integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1;
    localparam integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1;
    localparam integer MIDW = (LIDW > SIDW) ? LIDW : SIDW;
    localparam integer DCW = 1;
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
    localparam integer IC_RSP_BITS = GEN_WIDTH + FIDW + DCW + 32;
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
    logic [FETCH_BITS-1:0] fetch_packet;
    logic [DECODE_BITS-1:0] decode_uop;
    logic [GEN_WIDTH-1:0] current_gen;
    wire cp_has_free;
    logic [CIDW-1:0] cp_alloc_id;
    logic  cp_alloc_valid;
    logic [CP_ALLOC_BITS-1:0] cp_alloc_payload;
    logic [CHECKPOINT_DEPTH-1:0] cp_release_mask;
    (* keep *) logic squash_valid, fetch_redirect_valid, front_redirect_valid;
    logic [RW-1:0] squash_tag, rob_head, rob_tail;
    logic [CIDW-1:0] restore_cp_id;
    logic [32+GEN_WIDTH-1:0] fetch_redirect_payload;
    logic [31:0] front_redirect_pc;
    (* keep *) logic disp_valid, disp_ready, disp_fire;
    logic [DCW-1:0] disp_count;
    logic [ROB_ALLOC_BITS-1:0] disp_rob;
    logic [ALU_IQ_BITS-1:0] disp_alu;
    logic [MEM_IQ_BITS-1:0] disp_mem;
    logic [MEM_ALLOC_BITS-1:0] disp_lsq;
    logic  disp_src1_ready, disp_src2_ready;
    logic  alu_disp_valid, mem_disp_valid;
    logic  alu_disp_prepare, mem_disp_prepare;
    logic [ROB_CW-1:0] rob_free;
    wire alu_iq_has_free;
    wire mem_iq_has_free;
    wire lq_has_free;
    wire sq_has_free;
    logic [LIDW-1:0] lq_alloc_id;
    logic [SIDW-1:0] sq_alloc_id;
    logic [COMMIT_WIDTH-1:0] reg_commit_valid;
    logic [COMMIT_WIDTH*PW-1:0] reg_commit_payload;
    logic st_start_valid, st_done_valid;
    logic [SIDW-1:0] st_start_id;
    logic  alu_cand_valid, alu_cand_take;
    logic mem_cand_valid, mem_cand_take, mem_cand_src2_ready;
    wire [31:0] branch_operand1, branch_operand2;
    wire mem_store_data_valid;
    wire [PW-1:0] mem_store_psrc;
    logic [ALU_IQ_BITS-1:0] alu_cand_uop;
    logic [MEM_IQ_BITS-1:0] mem_cand_uop;
    logic [2*PW-1:0] rd_addr;
    logic [64-1:0] rd_data;
    logic  alu_exec_valid, alu_exec_ready;
    logic [ALU_EXEC_BITS-1:0] alu_exec_payload;
    logic mul_exec_valid, mul_exec_ready, mem_exec_valid, mem_exec_ready;
    wire mem_exec_preview_valid;
    logic [MUL_EXEC_BITS-1:0] mul_exec_payload;
    logic [MEM_EXEC_BITS-1:0] mem_exec_payload;
    logic  alu_result_valid, alu_result_ready, resolve_valid;
    logic [RESULT_BITS-1:0] alu_result_payload;
    logic [RESOLVE_BITS-1:0] resolve_payload;
    wire [31:0] lookup_pc;
    wire  pred_taken;
    wire [31:0] pred_npc;
    wire  train_valid;
    wire [BP_TRAIN_BITS-1:0] train_payload;
    logic mul_result_valid, mul_result_ready, lsu_result_valid, lsu_result_ready;
    logic [RESULT_BITS-1:0] mul_result_payload, lsu_result_payload;
    logic [WB_WIDTH-1:0] done_valid, write_valid;
    logic [WB_WIDTH*RW-1:0] done_tag;
    logic [WB_WIDTH*PW-1:0] write_pdst;
    logic [WB_WIDTH*32-1:0] write_value;
    localparam integer COMPLETION_WIDTH = 3;
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
    wire early_wake_valid, branch_exec_valid;
    wire [PW-1:0] early_wake_pdst;
    localparam integer IQ_WAKE_WIDTH=COMPLETION_WIDTH+1;
    wire [IQ_WAKE_WIDTH-1:0] iq_wake_valid={early_wake_valid,completion_valid};
    wire [IQ_WAKE_WIDTH*PW-1:0] iq_wake_pdst={early_wake_pdst,completion_pdst};
    localparam integer WAKE_SINK_BITS=COMPLETION_WIDTH*(PW+1);
    wire [5*WAKE_SINK_BITS-1:0] distributed_completion;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WAKE_SINK_BITS), .BRANCHES(5))
        distribute_completion({completion_valid,completion_pdst},distributed_completion);
    wire [(8)*RW-1:0] distributed_head;
    wire [(10)*(RW+1)-1:0] distributed_squash;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(RW), .BRANCHES(8))
        distribute_head(rob_head, distributed_head);
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(RW+1), .BRANCHES(10))
        distribute_recovery({squash_valid, squash_tag}, distributed_squash);
    wire [1:0] dispatch_kind = disp_rob[SIDW +: 2];
    wire dispatch_memory = dispatch_kind == 2 || dispatch_kind == 3;
    assign alu_disp_prepare = !dispatch_memory;
    assign mem_disp_prepare = dispatch_memory;
    assign alu_disp_valid = disp_fire && !dispatch_memory;
    assign mem_disp_valid = disp_fire && dispatch_memory;
    assign disp_ready = !distributed_squash[8*(RW+1)+RW] && rob_free != 0 &&
        (dispatch_memory ? mem_iq_has_free : alu_iq_has_free) &&
        (dispatch_kind != 2 || lq_has_free) && (dispatch_kind != 3 || sq_has_free);
    assign disp_fire = disp_valid && disp_ready;

    branch_predictor #(.BP_ENABLE(BP_ENABLE), .BTB_ENTRIES(BTB_ENTRIES), .BHT_ENTRIES(BHT_ENTRIES)) u_predictor (
        .clock, .reset, .lookup_pc, .pred_taken, .pred_npc, .train_valid, .train_payload);
    fetch #(.FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH), .IFETCH_OUTSTANDING(IFETCH_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH), .RESET_PC(RESET_PC), .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES)) u_fetch (
        .clock, .reset, .fetch_redirect_valid, .fetch_redirect_payload,
        .lookup_pc, .pred_taken, .pred_npc,
        .ic_req_valid, .ic_req_ready, .ic_req_payload, .ic_rsp_valid, .ic_rsp_payload,
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet);
    icache #(.FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH), .ICACHE_SIZE_BYTES(ICACHE_SIZE_BYTES), .ICACHE_WAYS(ICACHE_WAYS), .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES), .GEN_WIDTH(GEN_WIDTH)) u_icache (
        .clock, .reset, .fetch_redirect_valid,
        .ic_req_valid, .ic_req_ready, .ic_req_payload, .ic_rsp_valid, .ic_rsp_payload,
        .if_req_valid, .if_req_ready, .if_req_payload, .if_rsp_valid, .if_rsp_payload);
    decode u_decode (
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet,
        .decode_valid, .decode_ready, .decode_count, .decode_uop);
    rename #(.WAKE_WIDTH(COMPLETION_WIDTH), .COMMIT_WIDTH(COMMIT_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .IQ_ALU_DEPTH(IQ_ALU_DEPTH), .IQ_MEM_DEPTH(IQ_MEM_DEPTH), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_rename (
        .clock, .reset, .squash_valid(distributed_squash[(0)*(RW+1)+RW]), .restore_cp_id, .cp_release_mask,
        .cp_has_free, .cp_alloc_id, .decode_valid, .decode_ready, .decode_count, .decode_uop,
        .rob_free, .rob_tail, .alu_iq_has_free, .mem_iq_has_free, .lq_has_free, .sq_has_free,
        .lq_alloc_id, .sq_alloc_id, .disp_valid, .disp_ready, .disp_count,
        .disp_rob, .disp_alu, .disp_mem, .disp_lsq,
        .disp_src1_ready, .disp_src2_ready, .cp_alloc_valid, .cp_alloc_payload,
        .front_redirect_valid, .front_redirect_pc,
        .wake_valid(distributed_completion[COMPLETION_WIDTH*PW +: COMPLETION_WIDTH]),
        .wake_pdst(distributed_completion[0 +: COMPLETION_WIDTH*PW]),
        .reg_commit_valid, .reg_commit_payload);
    rob #(.WB_WIDTH(WB_WIDTH), .COMMIT_WIDTH(COMMIT_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .SQ_DEPTH(SQ_DEPTH)) u_rob (
        .clock, .reset, .squash_valid(distributed_squash[(1)*(RW+1)+RW]), .squash_tag(distributed_squash[(1)*(RW+1) +: RW]),
        .disp_fire, .disp_count, .disp_rob, .done_valid, .done_tag,
        .rob_free, .rob_tail, .rob_head, .reg_commit_valid, .reg_commit_payload,
        .st_start_valid, .st_start_id, .st_done_valid);
    branch_ctrl #(.ROB_DEPTH(ROB_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH), .GEN_WIDTH(GEN_WIDTH)) u_branch (
        .clock, .reset, .rob_head(distributed_head[(0)*RW +: RW]), .current_gen, .cp_has_free, .cp_alloc_id,
        .cp_alloc_valid, .cp_alloc_payload, .front_redirect_valid, .front_redirect_pc,
        .resolve_valid, .resolve_payload, .cp_release_mask,
        .train_valid, .train_payload,
        .squash_valid, .squash_tag, .restore_cp_id,
        .fetch_redirect_valid, .fetch_redirect_payload);
    iq_alu #(.WAKE_WIDTH(IQ_WAKE_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .IQ_ALU_DEPTH(IQ_ALU_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_iq_alu (
        .clock, .reset, .squash_valid(distributed_squash[(2)*(RW+1)+RW]), .squash_tag(distributed_squash[(2)*(RW+1) +: RW]), .rob_head(distributed_head[(1)*RW +: RW]),
        .disp_valid(alu_disp_valid), .disp_prepare(alu_disp_prepare), .disp_uop(disp_alu),
        .disp_src1_ready, .disp_src2_ready,
        .wake_valid({early_wake_valid,distributed_completion[WAKE_SINK_BITS+COMPLETION_WIDTH*PW +: COMPLETION_WIDTH]}),
        .wake_pdst({early_wake_pdst,distributed_completion[WAKE_SINK_BITS +: COMPLETION_WIDTH*PW]}),
        .alu_iq_has_free, .cand_valid(alu_cand_valid), .cand_uop(alu_cand_uop),
        .cand_take(alu_cand_take));
    iq_mem #(.WAKE_WIDTH(IQ_WAKE_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .IQ_MEM_DEPTH(IQ_MEM_DEPTH), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH)) u_iq_mem (
        .clock, .reset, .squash_valid(distributed_squash[(3)*(RW+1)+RW]), .squash_tag(distributed_squash[(3)*(RW+1) +: RW]), .rob_head(distributed_head[(2)*RW +: RW]),
        .disp_valid(mem_disp_valid), .disp_prepare(mem_disp_prepare), .disp_uop(disp_mem),
        .disp_src1_ready, .disp_src2_ready,
        .wake_valid({early_wake_valid,distributed_completion[2*WAKE_SINK_BITS+COMPLETION_WIDTH*PW +: COMPLETION_WIDTH]}),
        .wake_pdst({early_wake_pdst,distributed_completion[2*WAKE_SINK_BITS +: COMPLETION_WIDTH*PW]}),
        .mem_iq_has_free, .cand_valid(mem_cand_valid), .cand_src2_ready(mem_cand_src2_ready), .cand_uop(mem_cand_uop),
        .cand_take(mem_cand_take));
    issue #(.ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_issue (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .alu_cand_valid, .alu_cand_uop, .alu_cand_take,
        .mem_cand_valid, .mem_cand_src2_ready, .mem_cand_uop, .mem_cand_take, .rd_addr, .rd_data,
        .mem_store_data_valid, .mem_store_psrc,
        .forward_valid(distributed_completion[3*WAKE_SINK_BITS+COMPLETION_WIDTH*PW +: COMPLETION_WIDTH]),
        .forward_pdst(distributed_completion[3*WAKE_SINK_BITS +: COMPLETION_WIDTH*PW]), .forward_value(completion_value),
        .early_wake_valid, .early_wake_pdst, .branch_exec_valid, .branch_operand1, .branch_operand2,
        .alu_exec_valid, .alu_exec_ready, .alu_exec_payload,
        .mul_exec_valid, .mul_exec_ready, .mul_exec_payload,
        .mem_exec_valid, .mem_exec_preview_valid, .mem_exec_ready, .mem_exec_payload);
    prf #(.WB_WIDTH(WB_WIDTH), .PRF_SIZE(PRF_SIZE)) u_prf (
        .clock, .reset, .rd_addr, .rd_data, .write_valid, .write_pdst, .write_value);
        alu #(.ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) u_alu (
            .clock, .reset, .squash_valid(distributed_squash[9*(RW+1)+RW]), .squash_tag(distributed_squash[9*(RW+1) +: RW]), .rob_head(distributed_head[7*RW +: RW]),
            .exec_valid(alu_exec_valid), .resolve_exec_valid(branch_exec_valid), .branch_operand1, .branch_operand2, .exec_ready(alu_exec_ready),
            .exec_payload(alu_exec_payload[ALU_EXEC_BITS-1:0]),
            .result_valid(alu_result_valid), .result_ready(alu_result_ready),
            .result_payload(alu_result_payload[RESULT_BITS-1:0]),
            .resolve_valid(resolve_valid),
            .resolve_payload(resolve_payload[RESOLVE_BITS-1:0]));
    mul_div #(.ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE)) u_mul_div (
        .clock, .reset, .squash_valid(distributed_squash[(5)*(RW+1)+RW]), .squash_tag(distributed_squash[(5)*(RW+1) +: RW]), .rob_head(distributed_head[(4)*RW +: RW]),
        .exec_valid(mul_exec_valid), .exec_ready(mul_exec_ready), .exec_payload(mul_exec_payload),
        .result_valid(mul_result_valid), .result_ready(mul_result_ready),
        .result_payload(mul_result_payload));
    lsu #(.ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH), .LOAD_OUTSTANDING(LOAD_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH)) u_lsu (
        .clock, .reset, .squash_valid(distributed_squash[(6)*(RW+1)+RW]), .squash_tag(distributed_squash[(6)*(RW+1) +: RW]), .rob_head(distributed_head[(5)*RW +: RW]), .current_gen,
        .disp_valid(mem_disp_valid), .disp_lsq, .lq_has_free, .sq_has_free,
        .lq_alloc_id, .sq_alloc_id,
        .exec_valid(mem_exec_valid), .read_exec_valid(mem_exec_preview_valid), .exec_ready(mem_exec_ready), .exec_payload(mem_exec_payload),
        .store_data_valid(mem_store_data_valid), .store_psrc(mem_store_psrc),
        .forward_valid(distributed_completion[4*WAKE_SINK_BITS+COMPLETION_WIDTH*PW +: COMPLETION_WIDTH]),
        .forward_pdst(distributed_completion[4*WAKE_SINK_BITS +: COMPLETION_WIDTH*PW]), .forward_value(completion_value),
        .result_valid(lsu_result_valid), .result_ready(lsu_result_ready),
        .result_payload(lsu_result_payload),
        .st_start_valid, .st_start_id, .st_done_valid,
        .ld_req_valid, .ld_req_ready, .ld_req_payload, .ld_rsp_valid, .ld_rsp_payload,
        .st_req_valid, .st_req_ready, .st_req_payload, .st_rsp_valid);
    wb_arb #(.WB_WIDTH(WB_WIDTH), .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE)) u_wb (
        .clock, .reset, .squash_valid(distributed_squash[(7)*(RW+1)+RW]), .squash_tag(distributed_squash[(7)*(RW+1) +: RW]), .rob_head(distributed_head[(6)*RW +: RW]),
        .alu_result_valid, .alu_result_ready, .alu_result_payload,
        .mul_result_valid, .mul_result_ready, .mul_result_payload,
        .lsu_result_valid, .lsu_result_ready, .lsu_result_payload,
        .done_valid, .done_tag, .write_valid, .write_pdst, .write_value);
    dcache #(.BULK_REFILL(DATA_PREFETCH), .SIZE_BYTES(DCACHE_SIZE_BYTES), .WAYS(DCACHE_WAYS), .LINE_BYTES(DCACHE_LINE_BYTES), .LQ_DEPTH(LQ_DEPTH), .GEN_WIDTH(GEN_WIDTH)) u_dcache (
        .clock, .reset, .ld_req_valid, .ld_req_ready, .ld_req_payload,
        .ld_rsp_valid, .ld_rsp_payload, .st_req_valid, .st_req_ready,
        .st_req_payload, .st_rsp_valid,
        .mem_ld_req_valid, .mem_ld_req_ready, .mem_ld_req_payload,
        .mem_ld_rsp_valid, .mem_ld_rsp_payload, .mem_st_req_valid,
        .mem_st_req_ready, .mem_st_req_payload, .mem_st_rsp_valid,
        .line_req_valid, .line_req_ready, .line_rsp_valid, .line_rsp_data);
    generate if (DATA_PREFETCH!=0) begin : g_prefetch
    data_prefetch #(.LINE_BYTES(DCACHE_LINE_BYTES), .GEN_WIDTH(GEN_WIDTH)) prefetch (
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
    axi_bridge #(.LD_ID_WIDTH(DC_WORD_W+PREFETCH_ID_BITS), .AXI_RD_OUTSTANDING(AXI_RD_OUTSTANDING), .GEN_WIDTH(GEN_WIDTH), .IF_ID_WIDTH(IF_ID_WIDTH)) u_axi (
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

module issue_sched #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer TAG_BITS = RW,
    parameter integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 64,
    parameter integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32,
    parameter integer ALU_EXEC_BITS = TAG_BITS + CIDW + 6 + PW + 128,
    parameter integer MUL_EXEC_BITS = TAG_BITS + 3 + PW + 64,
    parameter integer MEM_EXEC_BITS = TAG_BITS + 3 + MIDW + 96
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [ISSUE_WIDTH-1:0] alu_cand_valid,
    input logic [ISSUE_WIDTH*ALU_IQ_BITS-1:0] alu_cand_uop,
    output logic [ISSUE_WIDTH-1:0] alu_cand_take,
    input logic mem_cand_valid,
    input logic [MEM_IQ_BITS-1:0] mem_cand_uop,
    output logic mem_cand_take,
    output logic [2*ISSUE_WIDTH*PW-1:0] rd_addr,
    input logic [2*ISSUE_WIDTH*32-1:0] rd_data,
    output logic [ISSUE_WIDTH-1:0] alu_exec_valid,
    input logic [ISSUE_WIDTH-1:0] alu_exec_ready,
    output logic [ISSUE_WIDTH*ALU_EXEC_BITS-1:0] alu_exec_payload,
    output logic mul_exec_valid,
    input logic mul_exec_ready,
    output logic [MUL_EXEC_BITS-1:0] mul_exec_payload,
    output logic mem_exec_valid,
    input logic mem_exec_ready,
    output logic [MEM_EXEC_BITS-1:0] mem_exec_payload
);
    logic [ISSUE_WIDTH-1:0] alu_busy;
    logic mul_used_alu, mem_used;
    logic mul_busy, mem_busy;
    logic [ALU_EXEC_BITS-1:0] alu_q [0:ISSUE_WIDTH-1];
    logic [MUL_EXEC_BITS-1:0] mul_q;
    logic [MEM_EXEC_BITS-1:0] mem_q;
    logic [ISSUE_WIDTH-1:0] slot_used;
    localparam integer CAND_COUNT = ISSUE_WIDTH + 1;
    localparam integer TREE_LEAVES = 2 ** $clog2(CAND_COUNT);
    localparam integer SRC_W = (CAND_COUNT > 1) ? $clog2(CAND_COUNT) : 1;
    logic [RW-1:0] alu_age [0:ISSUE_WIDTH-1];
    logic [RW-1:0] mem_age;
    logic [ISSUE_WIDTH-1:0] alu_is_mul, alu_survives;
    logic mem_survives;
    logic [ISSUE_WIDTH-1:0] take_alu_select [0:ISSUE_WIDTH-1];
    logic take_mem_select [0:ISSUE_WIDTH-1];
    logic tree_valid [0:ISSUE_WIDTH-1][1:2*TREE_LEAVES-1];
    logic [RW-1:0] tree_age [0:ISSUE_WIDTH-1][1:2*TREE_LEAVES-1];
    logic [SRC_W-1:0] tree_src [0:ISSUE_WIDTH-1][1:2*TREE_LEAVES-1];
    integer take_kind [0:ISSUE_WIDTH-1]; // 0 none, 1 ALU, 2 MUL, 3 MEM
    integer take_slot [0:ISSUE_WIDTH-1];
    integer free_slot;
    logic selected_mul;
    logic [ALU_IQ_BITS-1:0] selected_alu_item [0:ISSUE_WIDTH-1];
    logic [MEM_IQ_BITS-1:0] seq_mem_item;

    always_comb begin
        for (int s = 0; s < ISSUE_WIDTH; s = s + 1) begin
            alu_age[s] = alu_cand_uop[s*ALU_IQ_BITS+ALU_IQ_BITS-1 -: RW] - rob_head;
            alu_is_mul[s] = (alu_cand_uop[s*ALU_IQ_BITS+64+3*PW +: 6] >= 38 &&
                             alu_cand_uop[s*ALU_IQ_BITS+64+3*PW +: 6] <= 45);
            alu_survives[s] = alu_cand_valid[s] &&
                (!squash_valid || alu_age[s] <= (squash_tag - rob_head));
        end
        mem_age = mem_cand_uop[MEM_IQ_BITS-1 -: RW] - rob_head;
        mem_survives = mem_cand_valid &&
            (!squash_valid || mem_age <= (squash_tag - rob_head));
        alu_cand_take = 0;
        mem_cand_take = 0;
        rd_addr = 0;
        slot_used = alu_busy;
        mul_used_alu = 0;
        mem_used = 0;
        for (int k = 0; k < ISSUE_WIDTH; k = k + 1) begin
            take_kind[k] = 0;
            take_slot[k] = 0;
            take_alu_select[k] = 0;
            take_mem_select[k] = 0;
            selected_alu_item[k] = 0;
            selected_mul = 0;
            free_slot = -1;
            for (int s = 0; s < ISSUE_WIDTH; s = s + 1)
                if (free_slot < 0 && !slot_used[s]) free_slot = s;
            for (int leaf = 0; leaf < TREE_LEAVES; leaf = leaf + 1) begin
                tree_valid[k][TREE_LEAVES+leaf] = 0;
                tree_age[k][TREE_LEAVES+leaf] = {RW{1'b1}};
                tree_src[k][TREE_LEAVES+leaf] = SRC_W'(leaf);
            end
            for (int s = 0; s < ISSUE_WIDTH; s = s + 1) begin
                tree_valid[k][TREE_LEAVES+s] = alu_survives[s] && !alu_cand_take[s] &&
                    (alu_is_mul[s] ? (!mul_busy && !mul_used_alu) : (free_slot >= 0));
                tree_age[k][TREE_LEAVES+s] = alu_age[s];
            end
            tree_valid[k][TREE_LEAVES+ISSUE_WIDTH] =
                mem_survives && !mem_cand_take && !mem_busy && !mem_used;
            tree_age[k][TREE_LEAVES+ISSUE_WIDTH] = mem_age;
            for (int node = TREE_LEAVES-1; node > 0; node = node - 1) begin
                if (tree_valid[k][2*node] &&
                    (!tree_valid[k][2*node+1] ||
                     tree_age[k][2*node] <= tree_age[k][2*node+1])) begin
                    tree_valid[k][node] = 1;
                    tree_age[k][node] = tree_age[k][2*node];
                    tree_src[k][node] = tree_src[k][2*node];
                end else begin
                    tree_valid[k][node] = tree_valid[k][2*node+1];
                    tree_age[k][node] = tree_age[k][2*node+1];
                    tree_src[k][node] = tree_src[k][2*node+1];
                end
            end
            for (int s = 0; s < ISSUE_WIDTH; s = s + 1) begin
                take_alu_select[k][s] = tree_valid[k][1] && tree_src[k][1] == SRC_W'(s);
                selected_alu_item[k] |= alu_cand_uop[s*ALU_IQ_BITS +: ALU_IQ_BITS] &
                    {ALU_IQ_BITS{take_alu_select[k][s]}};
                selected_mul |= take_alu_select[k][s] && alu_is_mul[s];
            end
            take_mem_select[k] = tree_valid[k][1] &&
                tree_src[k][1] == SRC_W'(ISSUE_WIDTH);
            alu_cand_take |= take_alu_select[k];
            if (|take_alu_select[k]) begin
                take_kind[k] = selected_mul ? 2 : 1;
                rd_addr[(2*k)*PW +: PW] = selected_alu_item[k][64+PW +: PW];
                rd_addr[(2*k+1)*PW +: PW] = selected_alu_item[k][64 +: PW];
                if (selected_mul) mul_used_alu = 1;
                else begin
                    take_slot[k] = free_slot;
                    slot_used[free_slot] = 1;
                end
            end else if (take_mem_select[k]) begin
                take_kind[k] = 3;
                mem_cand_take = 1;
                rd_addr[(2*k)*PW +: PW] = mem_cand_uop[32+PW +: PW];
                rd_addr[(2*k+1)*PW +: PW] = mem_cand_uop[32 +: PW];
                mem_used = 1;
            end
        end
    end
    for (genvar s = 0; s < ISSUE_WIDTH; s = s + 1) begin : g_alu_output
        wire [TAG_BITS-1:0] tag_q = alu_q[s][ALU_EXEC_BITS-1 -: TAG_BITS];
        assign alu_exec_valid[s] = alu_busy[s] &&
            (!squash_valid || ((tag_q - rob_head) <= (squash_tag - rob_head)));
        assign alu_exec_payload[s*ALU_EXEC_BITS +: ALU_EXEC_BITS] = alu_q[s];
    end
    wire [TAG_BITS-1:0] mul_tag = mul_q[MUL_EXEC_BITS-1 -: TAG_BITS];
    wire [TAG_BITS-1:0] mem_tag = mem_q[MEM_EXEC_BITS-1 -: TAG_BITS];
    assign mul_exec_valid = mul_busy &&
        (!squash_valid || ((mul_tag - rob_head) <= (squash_tag - rob_head)));
    assign mem_exec_valid = mem_busy &&
        (!squash_valid || ((mem_tag - rob_head) <= (squash_tag - rob_head)));
    assign mul_exec_payload = mul_q;
    assign mem_exec_payload = mem_q;

    always_ff @(posedge clock) begin
        if (reset) begin
            alu_busy <= 0;
            mul_busy <= 0;
            mem_busy <= 0;
        end else begin
            for (int s = 0; s < ISSUE_WIDTH; s = s + 1) begin
                if (alu_busy[s] &&
                    ((alu_exec_valid[s] && alu_exec_ready[s]) ||
                     (squash_valid && !alu_exec_valid[s]))) alu_busy[s] <= 0;
            end
            if (mul_busy && ((mul_exec_valid && mul_exec_ready) ||
                             (squash_valid && !mul_exec_valid))) mul_busy <= 0;
            if (mem_busy && ((mem_exec_valid && mem_exec_ready) ||
                             (squash_valid && !mem_exec_valid))) mem_busy <= 0;
            for (int k = 0; k < ISSUE_WIDTH; k = k + 1) begin
                if (take_kind[k] == 1 || take_kind[k] == 2) begin
                    if (take_kind[k] == 1) begin
                        alu_busy[take_slot[k]] <= 1;
                        alu_q[take_slot[k]] <= {
                            selected_alu_item[k][ALU_IQ_BITS-1 -: TAG_BITS+CIDW+6+PW],
                            selected_alu_item[k][63:0],
                            rd_data[(2*k)*32 +: 32],
                            rd_data[(2*k+1)*32 +: 32]};
                    end else begin
                        mul_busy <= 1;
                        mul_q <= {
                            selected_alu_item[k][ALU_IQ_BITS-1 -: TAG_BITS],
                            (selected_alu_item[k][64+3*PW +: 3] - 3'd6),
                            selected_alu_item[k][64+2*PW +: PW],
                            rd_data[(2*k)*32 +: 32],
                            rd_data[(2*k+1)*32 +: 32]};
                    end
                end else if (take_kind[k] == 3) begin
                    seq_mem_item = mem_cand_uop;
                    mem_busy <= 1;
                    mem_q <= {
                        seq_mem_item[MEM_IQ_BITS-1 -: TAG_BITS+3+MIDW],
                        rd_data[(2*k)*32 +: 32],
                        seq_mem_item[31:0],
                        rd_data[(2*k+1)*32 +: 32]};
                end
            end
        end
    end
endmodule

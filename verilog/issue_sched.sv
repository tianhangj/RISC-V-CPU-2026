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
    integer take_kind [0:ISSUE_WIDTH-1]; // 0 none, 1 ALU, 2 MUL, 3 MEM
    integer take_src [0:ISSUE_WIDTH-1];
    integer take_slot [0:ISSUE_WIDTH-1];
    integer choice_kind, choice_src, choice_slot, free_slot;
    logic [RW-1:0] choice_age, age;
    logic [5:0] op;
    logic [TAG_BITS-1:0] tag;
    logic [ALU_IQ_BITS-1:0] alu_item;
    logic [MEM_IQ_BITS-1:0] mem_item;
    logic [ALU_IQ_BITS-1:0] seq_alu_item;
    logic [MEM_IQ_BITS-1:0] seq_mem_item;

    always_comb begin
        alu_cand_take = 0;
        mem_cand_take = 0;
        rd_addr = 0;
        slot_used = alu_busy;
        mul_used_alu = 0;
        mem_used = 0;
        for (int k = 0; k < ISSUE_WIDTH; k = k + 1) begin
            take_kind[k] = 0;
            take_src[k] = 0;
            take_slot[k] = 0;
            choice_kind = 0;
            choice_src = 0;
            choice_slot = 0;
            choice_age = {RW{1'b1}};
            free_slot = -1;
            for (int s = 0; s < ISSUE_WIDTH; s = s + 1)
                if (free_slot < 0 && !slot_used[s]) free_slot = s;
            for (int s = 0; s < ISSUE_WIDTH; s = s + 1) begin
                alu_item = alu_cand_uop[s*ALU_IQ_BITS +: ALU_IQ_BITS];
                op = alu_item[64+3*PW +: 6];
                tag = alu_item[ALU_IQ_BITS-1 -: TAG_BITS];
                age = tag - rob_head;
                if (alu_cand_valid[s] && !alu_cand_take[s] &&
                    (!squash_valid || age <= (squash_tag - rob_head)) &&
                    (((op >= 38 && op <= 45) && !mul_busy && !mul_used_alu) ||
                     ((op < 38 || op > 45) && free_slot >= 0)) &&
                    (choice_kind == 0 || age < choice_age)) begin
                    choice_kind = (op >= 38 && op <= 45) ? 2 : 1;
                    choice_src = s;
                    choice_slot = free_slot;
                    choice_age = age;
                end
            end
            mem_item = mem_cand_uop;
            tag = mem_item[MEM_IQ_BITS-1 -: TAG_BITS];
            age = tag - rob_head;
            if (mem_cand_valid && !mem_cand_take && !mem_busy && !mem_used &&
                (!squash_valid || age <= (squash_tag - rob_head)) &&
                (choice_kind == 0 || age < choice_age)) begin
                choice_kind = 3;
                choice_src = 0;
                choice_age = age;
            end
            take_kind[k] = choice_kind;
            take_src[k] = choice_src;
            take_slot[k] = choice_slot;
            if (choice_kind == 1 || choice_kind == 2) begin
                alu_item = alu_cand_uop[choice_src*ALU_IQ_BITS +: ALU_IQ_BITS];
                alu_cand_take[choice_src] = 1;
                rd_addr[(2*k)*PW +: PW] = alu_item[64+PW +: PW];
                rd_addr[(2*k+1)*PW +: PW] = alu_item[64 +: PW];
                if (choice_kind == 1) slot_used[choice_slot] = 1;
                else mul_used_alu = 1;
            end else if (choice_kind == 3) begin
                mem_item = mem_cand_uop;
                mem_cand_take = 1;
                rd_addr[(2*k)*PW +: PW] = mem_item[32+PW +: PW];
                rd_addr[(2*k+1)*PW +: PW] = mem_item[32 +: PW];
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
                    seq_alu_item = alu_cand_uop[take_src[k]*ALU_IQ_BITS +: ALU_IQ_BITS];
                    if (take_kind[k] == 1) begin
                        alu_busy[take_slot[k]] <= 1;
                        alu_q[take_slot[k]] <= {
                            seq_alu_item[ALU_IQ_BITS-1 -: TAG_BITS+CIDW+6+PW],
                            seq_alu_item[63:0],
                            rd_data[(2*k)*32 +: 32],
                            rd_data[(2*k+1)*32 +: 32]};
                    end else begin
                        mul_busy <= 1;
                        mul_q <= {
                            seq_alu_item[ALU_IQ_BITS-1 -: TAG_BITS],
                            (seq_alu_item[64+3*PW +: 3] - 3'd6),
                            seq_alu_item[64+2*PW +: PW],
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

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
    localparam integer ISSUE_READ_BITS = RW + CIDW + 6 + 3*PW + MIDW + 64;
    wire [ISSUE_WIDTH-1:0] issue_valid, issue_ready;
    wire [ISSUE_WIDTH*ISSUE_READ_BITS-1:0] issue_payload;
    issue_select #(.ISSUE_WIDTH(ISSUE_WIDTH), .ROB_DEPTH(ROB_DEPTH),
        .PRF_SIZE(PRF_SIZE), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH),
        .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) select_stage (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .alu_cand_valid, .alu_cand_uop, .alu_cand_take,
        .mem_cand_valid, .mem_cand_uop, .mem_cand_take,
        .issue_valid, .issue_ready, .issue_payload);
    operand_read #(.ISSUE_WIDTH(ISSUE_WIDTH), .ROB_DEPTH(ROB_DEPTH),
        .PRF_SIZE(PRF_SIZE), .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH),
        .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH)) read_stage (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .issue_valid, .issue_ready, .issue_payload, .rd_addr, .rd_data,
        .alu_exec_valid, .alu_exec_ready, .alu_exec_payload,
        .mul_exec_valid, .mul_exec_ready, .mul_exec_payload,
        .mem_exec_valid, .mem_exec_ready, .mem_exec_payload);
endmodule

// S6: select from registered IQ readiness, then own each selected instruction.
module issue_select #(
    parameter integer ISSUE_WIDTH=2, ROB_DEPTH=32, PRF_SIZE=64,
    parameter integer LQ_DEPTH=8, SQ_DEPTH=8, CHECKPOINT_DEPTH=4,
    parameter integer RW=$clog2(ROB_DEPTH), PW=$clog2(PRF_SIZE),
    parameter integer LIDW=(LQ_DEPTH>1)?$clog2(LQ_DEPTH):1,
    parameter integer SIDW=(SQ_DEPTH>1)?$clog2(SQ_DEPTH):1,
    parameter integer MIDW=(LIDW>SIDW)?LIDW:SIDW,
    parameter integer CIDW=(CHECKPOINT_DEPTH>1)?$clog2(CHECKPOINT_DEPTH):1,
    parameter integer ALU_IQ_BITS=RW+CIDW+6+3*PW+64,
    parameter integer MEM_IQ_BITS=RW+3+MIDW+2*PW+32,
    parameter integer ISSUE_READ_BITS=RW+CIDW+6+3*PW+MIDW+64
) (
    input wire clock, reset, squash_valid,
    input wire [RW-1:0] squash_tag, rob_head,
    input wire [ISSUE_WIDTH-1:0] alu_cand_valid,
    input wire [ISSUE_WIDTH*ALU_IQ_BITS-1:0] alu_cand_uop,
    output reg [ISSUE_WIDTH-1:0] alu_cand_take,
    input wire mem_cand_valid,
    input wire [MEM_IQ_BITS-1:0] mem_cand_uop,
    output reg mem_cand_take,
    output wire [ISSUE_WIDTH-1:0] issue_valid,
    input wire [ISSUE_WIDTH-1:0] issue_ready,
    output wire [ISSUE_WIDTH*ISSUE_READ_BITS-1:0] issue_payload
);
    reg [1:0] count_q [0:ISSUE_WIDTH-1];
    reg [ISSUE_READ_BITS-1:0] first_q [0:ISSUE_WIDTH-1], second_q [0:ISSUE_WIDTH-1];
    reg [ISSUE_READ_BITS-1:0] enqueue [0:ISSUE_WIDTH-1];
    reg [ISSUE_WIDTH-1:0] enqueue_valid;
    reg used_mul, used_mem;
    integer chosen, best_age, candidate_age;
    reg [5:0] op;
    reg [ALU_IQ_BITS-1:0] item;
    function automatic survives(input [RW-1:0] tag);
        survives = !squash_valid || RW'(tag-rob_head) <= RW'(squash_tag-rob_head);
    endfunction
    always @* begin
        alu_cand_take=0; mem_cand_take=0; enqueue_valid=0;
        used_mul=0; used_mem=0; item=0; op=0;
        chosen=-1; best_age=0; candidate_age=0;
        for (integer lane=0; lane<ISSUE_WIDTH; lane=lane+1) begin
            enqueue[lane]=0;
            chosen=-1; best_age=ROB_DEPTH;
            if (!reset && count_q[lane]<2) begin
                for (integer c=0; c<ISSUE_WIDTH; c=c+1) begin
                    op=alu_cand_uop[c*ALU_IQ_BITS+64+3*PW +: 6];
                    candidate_age=int'(RW'(alu_cand_uop[c*ALU_IQ_BITS+ALU_IQ_BITS-1 -: RW]-rob_head));
                    if (alu_cand_valid[c] && !alu_cand_take[c] &&
                        survives(alu_cand_uop[c*ALU_IQ_BITS+ALU_IQ_BITS-1 -: RW]) &&
                        (!(op>=38 && op<=45) || !used_mul) && candidate_age<best_age) begin
                        chosen=c; best_age=candidate_age;
                    end
                end
                candidate_age=int'(RW'(mem_cand_uop[MEM_IQ_BITS-1 -: RW]-rob_head));
                if (mem_cand_valid && !used_mem && survives(mem_cand_uop[MEM_IQ_BITS-1 -: RW]) &&
                    candidate_age<best_age) chosen=ISSUE_WIDTH;
                if (chosen==ISSUE_WIDTH) begin
                    mem_cand_take=1; used_mem=1; enqueue_valid[lane]=1;
                    enqueue[lane]={mem_cand_uop[MEM_IQ_BITS-1 -: RW], {CIDW{1'b0}},
                        (6'd30+{3'b0,mem_cand_uop[32+2*PW+MIDW +: 3]}), {PW{1'b0}},
                        mem_cand_uop[32+PW +: PW], mem_cand_uop[32 +: PW],
                        mem_cand_uop[32+2*PW +: MIDW], 32'b0, mem_cand_uop[31:0]};
                end else if (chosen>=0) begin
                    item=alu_cand_uop[chosen*ALU_IQ_BITS +: ALU_IQ_BITS];
                    alu_cand_take[chosen]=1; enqueue_valid[lane]=1;
                    op=item[64+3*PW +: 6];
                    if (op>=38 && op<=45) used_mul=1;
                    enqueue[lane]={item[ALU_IQ_BITS-1:64], {MIDW{1'b0}}, item[63:0]};
                end
            end
        end
    end
    for (genvar lane=0; lane<ISSUE_WIDTH; lane=lane+1) begin : g_queue
        wire first_live=count_q[lane]!=0 && survives(first_q[lane][ISSUE_READ_BITS-1 -: RW]);
        wire second_live=count_q[lane]==2 && survives(second_q[lane][ISSUE_READ_BITS-1 -: RW]);
        wire pop=issue_valid[lane] && issue_ready[lane];
        assign issue_valid[lane]=!reset && first_live;
        assign issue_payload[lane*ISSUE_READ_BITS +: ISSUE_READ_BITS]=first_q[lane];
        wire first_copy = squash_valid ?
            !(first_live && !pop) && second_live : pop && count_q[lane]==2;
        wire first_enqueue = enqueue_valid[lane] && (squash_valid ?
            !(first_live && !pop) && !second_live : count_q[lane]==0 || pop);
        wire second_enqueue = enqueue_valid[lane] && (squash_valid ?
            (first_live && !pop) || second_live : !(count_q[lane]==0 || pop));
        localparam integer GROUPS=(ISSUE_READ_BITS+15)/16;
        wire [3*GROUPS-1:0] capture_control;
        (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(3), .BRANCHES(GROUPS))
            distribute_capture({second_enqueue,first_enqueue,first_copy},capture_control);
        for (genvar g=0; g<GROUPS; g=g+1) begin : g_capture
            localparam integer FIRST=16*g;
            localparam integer BITS=(ISSUE_READ_BITS-FIRST<16)?ISSUE_READ_BITS-FIRST:16;
            always @(posedge clock) begin
                if (capture_control[3*g])
                    first_q[lane][FIRST +: BITS]<=second_q[lane][FIRST +: BITS];
                if (capture_control[3*g+1])
                    first_q[lane][FIRST +: BITS]<=enqueue[lane][FIRST +: BITS];
                if (capture_control[3*g+2])
                    second_q[lane][FIRST +: BITS]<=enqueue[lane][FIRST +: BITS];
            end
        end
        always @(posedge clock) begin
            if (reset) count_q[lane]<=0;
            else if (squash_valid) begin
                // Enqueue, pop and compaction all use the pre-edge head.
                if (first_live && !pop)
                    count_q[lane]<=2'(1+int'(second_live)+int'(enqueue_valid[lane]));
                else if (second_live)
                    count_q[lane]<=2'(1+int'(enqueue_valid[lane]));
                else count_q[lane]<=2'(enqueue_valid[lane]);
            end else count_q[lane]<=count_q[lane]+2'(enqueue_valid[lane])-2'(pop);
        end
    end
endmodule

// S7: only registered physical addresses reach PRF; execution operands hold.
module operand_read #(
    parameter integer ISSUE_WIDTH=2, ROB_DEPTH=32, PRF_SIZE=64,
    parameter integer LQ_DEPTH=8, SQ_DEPTH=8, CHECKPOINT_DEPTH=4,
    parameter integer RW=$clog2(ROB_DEPTH), PW=$clog2(PRF_SIZE),
    parameter integer LIDW=(LQ_DEPTH>1)?$clog2(LQ_DEPTH):1,
    parameter integer SIDW=(SQ_DEPTH>1)?$clog2(SQ_DEPTH):1,
    parameter integer MIDW=(LIDW>SIDW)?LIDW:SIDW,
    parameter integer CIDW=(CHECKPOINT_DEPTH>1)?$clog2(CHECKPOINT_DEPTH):1,
    parameter integer ISSUE_READ_BITS=RW+CIDW+6+3*PW+MIDW+64,
    parameter integer ALU_EXEC_BITS=RW+CIDW+6+PW+128,
    parameter integer MUL_EXEC_BITS=RW+3+PW+64,
    parameter integer MEM_EXEC_BITS=RW+3+MIDW+96
) (
    input wire clock, reset, squash_valid,
    input wire [RW-1:0] squash_tag, rob_head,
    input wire [ISSUE_WIDTH-1:0] issue_valid,
    input wire [ISSUE_WIDTH*ISSUE_READ_BITS-1:0] issue_payload,
    output reg [ISSUE_WIDTH-1:0] issue_ready,
    output wire [2*ISSUE_WIDTH*PW-1:0] rd_addr,
    input wire [2*ISSUE_WIDTH*32-1:0] rd_data,
    output wire [ISSUE_WIDTH-1:0] alu_exec_valid,
    input wire [ISSUE_WIDTH-1:0] alu_exec_ready,
    output wire [ISSUE_WIDTH*ALU_EXEC_BITS-1:0] alu_exec_payload,
    output wire mul_exec_valid,
    input wire mul_exec_ready,
    output wire [MUL_EXEC_BITS-1:0] mul_exec_payload,
    output wire mem_exec_valid,
    input wire mem_exec_ready,
    output wire [MEM_EXEC_BITS-1:0] mem_exec_payload
);
    reg [ISSUE_WIDTH-1:0] alu_busy;
    reg mul_busy, mem_busy;
    reg [ALU_EXEC_BITS-1:0] alu_q [0:ISSUE_WIDTH-1];
    reg [MUL_EXEC_BITS-1:0] mul_q;
    reg [MEM_EXEC_BITS-1:0] mem_q;
    wire [ISSUE_READ_BITS-1:0] item [0:ISSUE_WIDTH-1];
    wire [5:0] op [0:ISSUE_WIDTH-1];
    wire [RW-1:0] tag [0:ISSUE_WIDTH-1];
    integer mul_lane, mem_lane, mul_age, mem_age, a;
    function automatic survives(input [RW-1:0] t);
        survives=!squash_valid || RW'(t-rob_head)<=RW'(squash_tag-rob_head);
    endfunction
    for (genvar k=0; k<ISSUE_WIDTH; k=k+1) begin : g_port
        assign item[k]=issue_payload[k*ISSUE_READ_BITS +: ISSUE_READ_BITS];
        assign op[k]=item[k][64+MIDW+3*PW +: 6];
        assign tag[k]=item[k][ISSUE_READ_BITS-1 -: RW];
        assign rd_addr[2*k*PW +: PW]=item[k][64+MIDW+PW +: PW];
        assign rd_addr[(2*k+1)*PW +: PW]=item[k][64+MIDW +: PW];
        assign alu_exec_valid[k]=!reset && alu_busy[k] && survives(alu_q[k][ALU_EXEC_BITS-1 -: RW]);
        assign alu_exec_payload[k*ALU_EXEC_BITS +: ALU_EXEC_BITS]=alu_q[k];
    end
    assign mul_exec_valid=!reset && mul_busy && survives(mul_q[MUL_EXEC_BITS-1 -: RW]);
    // LSU filters the AGU tag before updating LSQ state. It also discards a
    // younger same-edge completion at WB, so recovery need not gate this offer
    // and feed back through completion wakeup into IS arbitration.
    assign mem_exec_valid=!reset && mem_busy;
    assign mul_exec_payload=mul_q;
    assign mem_exec_payload=mem_q;
    always @* begin
        issue_ready=0; mul_lane=-1; mem_lane=-1;
        mul_age=ROB_DEPTH; mem_age=ROB_DEPTH; a=0;
        for (integer k=0; k<ISSUE_WIDTH; k=k+1) begin
            a=int'(RW'(tag[k]-rob_head));
            if (!reset && issue_valid[k] && survives(tag[k])) begin
                if (op[k]>=38 && op[k]<=45) begin
                    if ((!mul_busy || mul_exec_ready) && a<mul_age) begin mul_lane=k; mul_age=a; end
                end else if (op[k]>=30 && op[k]<=37) begin
                    if ((!mem_busy || mem_exec_ready) && a<mem_age) begin mem_lane=k; mem_age=a; end
                end else issue_ready[k]=!alu_busy[k] || alu_exec_ready[k];
            end
        end
        if (mul_lane>=0) issue_ready[mul_lane]=1;
        if (mem_lane>=0) issue_ready[mem_lane]=1;
    end
    always @(posedge clock) begin
        if (reset) begin alu_busy<=0; mul_busy<=0; mem_busy<=0; end
        else begin
            for (integer k=0; k<ISSUE_WIDTH; k=k+1) begin
                if (alu_busy[k] && (alu_exec_ready[k] || !survives(alu_q[k][ALU_EXEC_BITS-1 -: RW]))) alu_busy[k]<=0;
                if (issue_valid[k] && issue_ready[k] && !(op[k]>=30 && op[k]<=45)) begin
                    alu_busy[k]<=1;
                    alu_q[k]<={item[k][ISSUE_READ_BITS-1 -: RW+CIDW+6+PW], item[k][63:0],
                        rd_data[2*k*32 +: 32], rd_data[(2*k+1)*32 +: 32]};
                end
            end
            if (mul_busy && (mul_exec_ready || !survives(mul_q[MUL_EXEC_BITS-1 -: RW]))) mul_busy<=0;
            if (mem_busy && (mem_exec_ready || !survives(mem_q[MEM_EXEC_BITS-1 -: RW]))) mem_busy<=0;
            if (mul_lane>=0) begin
                mul_busy<=1;
                mul_q<={tag[mul_lane], (op[mul_lane][2:0]-3'd6),
                    item[mul_lane][64+MIDW+2*PW +: PW],
                    rd_data[2*mul_lane*32 +: 32], rd_data[(2*mul_lane+1)*32 +: 32]};
            end
            if (mem_lane>=0) begin
                mem_busy<=1;
                mem_q<={tag[mem_lane], (op[mem_lane][2:0]-3'd6), item[mem_lane][64 +: MIDW],
                    rd_data[2*mem_lane*32 +: 32], item[mem_lane][31:0], rd_data[(2*mem_lane+1)*32 +: 32]};
            end
        end
    end
endmodule

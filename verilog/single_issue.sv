// Single issue: choose a ready IQ entry and capture its operands at one edge.
// ALU wakeup precedes its registered result by one cycle. Source identities
// remain with the operands so the result can be forwarded at execution.
module single_issue #(
    parameter integer ROB_DEPTH=32, PRF_SIZE=64, LQ_DEPTH=8, SQ_DEPTH=8,
    parameter integer CHECKPOINT_DEPTH=4, FORWARD_WIDTH=3,
    parameter integer RW=$clog2(ROB_DEPTH), PW=$clog2(PRF_SIZE),
    parameter integer LIDW=(LQ_DEPTH>1)?$clog2(LQ_DEPTH):1,
    parameter integer SIDW=(SQ_DEPTH>1)?$clog2(SQ_DEPTH):1,
    parameter integer MIDW=(LIDW>SIDW)?LIDW:SIDW,
    parameter integer CIDW=(CHECKPOINT_DEPTH>1)?$clog2(CHECKPOINT_DEPTH):1,
    parameter integer ALU_IQ_BITS=RW+CIDW+6+3*PW+64,
    parameter integer MEM_IQ_BITS=RW+3+MIDW+2*PW+32,
    parameter integer ALU_EXEC_BITS=RW+CIDW+6+PW+128,
    parameter integer MUL_EXEC_BITS=RW+3+PW+64,
    parameter integer MEM_EXEC_BITS=RW+3+MIDW+96
) (
    input wire clock, reset, squash_valid,
    input wire [RW-1:0] squash_tag, rob_head,
    input wire alu_cand_valid, mem_cand_valid, mem_cand_src2_ready,
    input wire [ALU_IQ_BITS-1:0] alu_cand_uop,
    input wire [MEM_IQ_BITS-1:0] mem_cand_uop,
    output wire alu_cand_take, mem_cand_take,
    output wire [2*PW-1:0] rd_addr,
    input wire [63:0] rd_data,
    input wire [FORWARD_WIDTH-1:0] forward_valid,
    input wire [FORWARD_WIDTH*PW-1:0] forward_pdst,
    input wire [FORWARD_WIDTH*32-1:0] forward_value,
    output wire mem_store_data_valid,
    output wire [PW-1:0] mem_store_psrc,
    output wire branch_exec_valid,
    output wire early_wake_valid,
    output wire [PW-1:0] early_wake_pdst,
    output wire alu_exec_valid, mul_exec_valid, mem_exec_valid,
    input wire alu_exec_ready, mul_exec_ready, mem_exec_ready,
    output wire [ALU_EXEC_BITS-1:0] alu_exec_payload,
    output wire [MUL_EXEC_BITS-1:0] mul_exec_payload,
    output wire [MEM_EXEC_BITS-1:0] mem_exec_payload
);
    reg [2:0] busy;
    reg mem_data_ready;
    reg mem_data_forward;
    reg [ALU_EXEC_BITS-1:0] alu_q;
    reg [MUL_EXEC_BITS-1:0] mul_q;
    reg [MEM_EXEC_BITS-1:0] mem_q;
    reg [PW-1:0] src1 [0:2], src2 [0:2];
    reg [31:0] operand1 [0:2], operand2 [0:2];
    reg [31:0] forwarded1 [0:2], forwarded2 [0:2];
    wire [2:0] ready={mem_exec_ready,mul_exec_ready,alu_exec_ready};
    wire [5:0] alu_op=alu_cand_uop[64+3*PW +: 6];
    wire is_mul=alu_op>=38 && alu_op<=45;
    wire [RW-1:0] alu_tag=alu_cand_uop[ALU_IQ_BITS-1 -: RW];
    wire [RW-1:0] mem_tag=mem_cand_uop[MEM_IQ_BITS-1 -: RW];
    function automatic survives(input [RW-1:0] tag);
        survives=!squash_valid || RW'(tag-rob_head)<=RW'(squash_tag-rob_head);
    endfunction
    wire alu_offer=alu_cand_valid &&
        (is_mul?(!busy[1] || mul_exec_ready):(!busy[0] || alu_exec_ready));
    wire mem_offer=mem_cand_valid && (!busy[2] || mem_exec_ready);
    wire select_mem=mem_offer && (!alu_offer || RW'(mem_tag-rob_head)<RW'(alu_tag-rob_head));
    assign alu_cand_take=!reset && alu_offer && !select_mem;
    assign mem_cand_take=!reset && select_mem;
    assign rd_addr=select_mem ?
        {mem_cand_uop[32 +: PW],mem_cand_uop[32+PW +: PW]} :
        {alu_cand_uop[64 +: PW],alu_cand_uop[64+PW +: PW]};
    assign alu_exec_valid=!reset && busy[0] && survives(alu_q[ALU_EXEC_BITS-1 -: RW]);
    assign mul_exec_valid=!reset && busy[1] && survives(mul_q[MUL_EXEC_BITS-1 -: RW]);
    assign mem_exec_valid=!reset && busy[2] && survives(mem_q[MEM_EXEC_BITS-1 -: RW]);
    // Cancellation removes dependent younger IQ entries at the same edge.
    // Do not route squash through this predictive wakeup's selection path.
    assign early_wake_valid=!reset && busy[0] && alu_exec_ready;
    assign branch_exec_valid=early_wake_valid;
    assign early_wake_pdst=alu_q[128 +: PW];
    assign mem_store_psrc=src2[2];
    assign mem_store_data_valid=mem_data_ready || mem_data_forward;
    assign alu_exec_payload={alu_q[ALU_EXEC_BITS-1:64],forwarded1[0],forwarded2[0]};
    assign mul_exec_payload={mul_q[MUL_EXEC_BITS-1:64],forwarded1[1],forwarded2[1]};
    assign mem_exec_payload={mem_q[MEM_EXEC_BITS-1:96],forwarded1[2],mem_q[63:32],forwarded2[2]};
    always @* begin
        mem_data_forward=0;
        for (integer w=0; w<FORWARD_WIDTH; w=w+1)
            if (forward_valid[w] && src2[2]==forward_pdst[w*PW +: PW]) mem_data_forward=1;
        for (integer lane=0; lane<3; lane=lane+1) begin
            forwarded1[lane]=operand1[lane]; forwarded2[lane]=operand2[lane];
            for (integer w=0; w<FORWARD_WIDTH; w=w+1) begin
                if (forward_valid[w] && src1[lane]!=0 && src1[lane]==forward_pdst[w*PW +: PW])
                    forwarded1[lane]=forward_value[w*32 +: 32];
                if (forward_valid[w] && src2[lane]!=0 && src2[lane]==forward_pdst[w*PW +: PW])
                    forwarded2[lane]=forward_value[w*32 +: 32];
            end
        end
    end
    always @(posedge clock) begin
        if (reset) busy<=0;
        else begin
            if (mem_data_forward) mem_data_ready<=1;
            if (ready[0] || !survives(alu_q[ALU_EXEC_BITS-1 -: RW])) busy[0]<=0;
            if (ready[1] || !survives(mul_q[MUL_EXEC_BITS-1 -: RW])) busy[1]<=0;
            if (ready[2] || !survives(mem_q[MEM_EXEC_BITS-1 -: RW])) busy[2]<=0;
            // Preserve forwarded values even when the execution unit stalls.
            for (integer lane=0; lane<3; lane=lane+1) begin
                operand1[lane]<=forwarded1[lane]; operand2[lane]<=forwarded2[lane];
            end
            if (alu_cand_take) begin
                if (is_mul) begin
                    busy[1]<=survives(alu_tag);
                    mul_q<={alu_tag,(alu_op[2:0]-3'd6),alu_cand_uop[64+2*PW +: PW],64'b0};
                    src1[1]<=rd_addr[0 +: PW]; src2[1]<=rd_addr[PW +: PW];
                    operand1[1]<=rd_data[31:0]; operand2[1]<=rd_data[63:32];
                end else begin
                    busy[0]<=survives(alu_tag);
                    alu_q<={alu_cand_uop[ALU_IQ_BITS-1:64+2*PW],alu_cand_uop[63:0],64'b0};
                    src1[0]<=rd_addr[0 +: PW]; src2[0]<=rd_addr[PW +: PW];
                    operand1[0]<=rd_data[31:0]; operand2[0]<=rd_data[63:32];
                end
            end
            if (mem_cand_take) begin
                busy[2]<=survives(mem_tag);
                mem_data_ready<=mem_cand_src2_ready;
                mem_q<={mem_cand_uop[MEM_IQ_BITS-1:32+2*PW],32'b0,mem_cand_uop[31:0],32'b0};
                src1[2]<=rd_addr[0 +: PW]; src2[2]<=rd_addr[PW +: PW];
                operand1[2]<=rd_data[31:0]; operand2[2]<=rd_data[63:32];
            end
        end
    end
endmodule
